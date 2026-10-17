package com.lightningteam.suchmusic.band

import android.content.Context
import android.util.Log
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * 真机适配器：通过**反射**调用小米官方 `xms-wearable-lib`（`com.xiaomi.xms.wearable.*`）。
 *
 * 之所以用反射：官方 AAR 因专有许可**不能随仓库分发**，若直接 `import com.xiaomi.xms.wearable.*`
 * 会造成编译期硬依赖，导致没有该 AAR 时整个工程无法构建。反射保证：
 * - 没有 AAR → [isAvailable] 返回 false，[BandChannelBridge] 自动回退到 [NoopBandAdapter]；
 * - 放入 AAR 后重新构建 → 运行时类存在，本适配器启用，真机通信生效。
 *
 * 对应官方文档 v1.4 的 API（见 docs/ARCH-手环通信.md §1.1 F6）：
 * `Wearable.getNodeApi/getAuthApi/getMessageApi`、`NodeApi.getConnectedNodes()`、
 * `MessageApi.sendMessage(nodeId, byte[])`、`OnMessageReceivedListener.onMessageReceived(nodeId, byte[])`、
 * `AuthApi.checkPermission(nodeId, Permission.DEVICE_MANAGER)`。
 *
 * 由于无法在本沙箱真机验证（文档 §7 的 V2b），所有反射调用都做了**多签名/多命名兜底**
 * 与 **try/catch 静默降级**；不确定项以「返回安全值」为准则，绝不上抛。
 */
class XmsWearableAdapter(private val context: Context) : BandAdapter {

    companion object {
        private const val TAG = "XmsBandAdapter"

        private const val CLS_WEARABLE = "com.xiaomi.xms.wearable.Wearable"
        // 注意：Permission 在 auth 子包下（com.xiaomi.xms.wearable.auth.Permission），
        // 写成 com.xiaomi.xms.wearable.Permission 会 ClassNotFound → 权限检查永远失败。
        private const val CLS_PERMISSION = "com.xiaomi.xms.wearable.auth.Permission"
        private const val CLS_MSG_LISTENER =
            "com.xiaomi.xms.wearable.message.OnMessageReceivedListener"

        /** 节点 id：Node 的 `id` 是**公有字段**（非 getId()），故先取字段再兜底方法。 */
        private val NODE_ID_METHODS = arrayOf("getId", "getNodeId")

        /** 注册消息监听的候选方法名 */
        private val ADD_LISTENER_METHODS = arrayOf(
            "addMessageReceivedListener",
            "registerMessageReceivedListener",
            "addListener",
            "registerListener",
        )

        /** 发送消息的候选方法名 */
        private val SEND_METHODS = arrayOf("sendMessage", "send")

        /** 反射调用失败的哨兵值（与合法返回 null 区分；单例，可用引用/结构相等判定）。 */
        private val INVOKE_FAILED: Any = Any()
    }

    private var nodeApi: Any? = null
    private var authApi: Any? = null
    private var messageApi: Any? = null
    private var serviceApi: Any? = null
    private var serviceListenerProxy: Any? = null
    private var listenerProxy: Any? = null

    @Volatile
    private var currentNode: String? = null

    @Volatile
    private var permissionGranted = false

    @Volatile
    private var available = false

    @Volatile
    private var lastError: String? = null

    @Volatile
    private var installState: String = BandAdapterDefaults.STATE_UNKNOWN

    /** 当前监听者（异步发现到节点后需要用它注册监听）。 */
    private var activeListener: BandMessageListener? = null

    /** 节点发现是否处于运行态（stop 后停止重试）。 */
    @Volatile
    private var discovering = false

    /** 一轮发现是否在途，避免并发重复调用。 */
    @Volatile
    private var discoverInflight = false

    /** 已发现节点数（诊断用，区分「服务没连上」与「拿到了节点但注册失败」）。 */
    @Volatile
    private var lastNodeCount = -1

    private val retryHandler = android.os.Handler(android.os.Looper.getMainLooper())

    private val discoveryRetry = Runnable { discoverNodeAsync() }

    init {
        // 仅探测类是否存在（不初始化），决定本适配器是否启用。
        available = try {
            Class.forName(CLS_WEARABLE)
            true
        } catch (e: Throwable) {
            lastError = "Wearable 类不可用: ${e.message}"
            false
        }
    }

    override fun isAvailable(): Boolean = available

    override fun currentNodeId(): String? = currentNode

    /**
     * 启动链路。
     *
     * **关键修正（v0.14.7）**：官方 `NodeApi.getConnectedNodes()` 返回
     * `Task<List<Node>>`（**异步**）。旧实现同步取 `getResult()`，任务未完成时永远拿不到，
     * 于是 [start] 判失败 → 手机端一直停在「连接中」。
     *
     * 现在：只要 SDK 可用就立即返回 true（表示链路已进入「连接中」），
     * 节点发现交给异步回调 + 3 秒重试，直到拿到节点并注册监听。
     */
    override fun start(listener: BandMessageListener): Boolean {
        if (!available) return false
        return try {
            ensureApis()
            activeListener = listener
            discovering = true
            val node = currentNode
            if (node != null) {
                registerListener(node, listener)
                requestPermissionAsync(node)
                queryInstallState(node)
            } else {
                discoverNodeAsync()
            }
            true
        } catch (e: Throwable) {
            lastError = e.message
            Log.w(TAG, "start 失败: ${e.message}")
            false
        }
    }

    /**
     * 异步发现已连接节点：`getConnectedNodes()` → 成功回调拿 `List<Node>` → 取 `node.id`。
     * 失败或空列表时 3 秒后重试（手环可能后连上）。
     */
    private fun discoverNodeAsync() {
        val api = nodeApi ?: return
        if (!discovering || discoverInflight) return
        discoverInflight = true
        val task = invoke(api, "getConnectedNodes", emptyArray(), *emptyArray())
        if (task == INVOKE_FAILED || task == null) {
            discoverInflight = false
            lastError = "getConnectedNodes 调用失败（SDK 服务可能未就绪）"
            Log.w(TAG, lastError ?: "")
            scheduleDiscoveryRetry()
            return
        }
        // 少数实现可能直接返回列表而非 Task
        if (task is Iterable<*> || task is Array<*>) {
            onNodesDiscovered(task)
            return
        }
        attachTaskSuccess(task) { v -> onNodesDiscovered(v) }
        attachTaskFailure(task) { e ->
            discoverInflight = false
            lastError = "getConnectedNodes 失败: ${e.message}（检查小米运动健康是否在运行）"
            Log.w(TAG, lastError ?: "")
            scheduleDiscoveryRetry()
        }
    }

    private fun onNodesDiscovered(raw: Any?) {
        discoverInflight = false
        if (!discovering) return
        val list: List<Any> = when {
            raw is Iterable<*> -> raw.filterNotNull()
            raw is Array<*> -> raw.filterNotNull()
            else -> emptyList()
        }
        lastNodeCount = list.size
        val id = list.asSequence().mapNotNull { nodeIdOf(it) }.firstOrNull()
        if (id.isNullOrEmpty()) {
            lastError = "未发现已连接的手环节点（手机与手环需保持蓝牙互连，且小米运动健康在运行）"
            scheduleDiscoveryRetry()
            return
        }
        currentNode = id
        lastError = null
        Log.i(TAG, "发现手环节点: $id（共 ${list.size} 个）")
        activeListener?.let { registerListener(id, it) }
        requestPermissionAsync(id)
        queryInstallState(id)
    }

    private fun scheduleDiscoveryRetry() {
        if (!discovering) return
        retryHandler.removeCallbacks(discoveryRetry)
        retryHandler.postDelayed(discoveryRetry, 3000)
    }

    override fun stop() {
        discovering = false
        discoverInflight = false
        retryHandler.removeCallbacks(discoveryRetry)
        activeListener = null
        unregisterListener()
        // 注销服务连接监听（保持与注册对称）
        try {
            val api = serviceApi
            val proxy = serviceListenerProxy
            if (api != null && proxy != null) {
                val iface = Class.forName("com.xiaomi.xms.wearable.service.OnServiceConnectionListener")
                invoke(api, "unregisterServiceConnectionListener", arrayOf(iface), proxy)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "注销服务监听失败: ${e.message}")
        }
        serviceListenerProxy = null
        serviceApi = null
        nodeApi = null
        authApi = null
        messageApi = null
        currentNode = null
        permissionGranted = false
    }

    override fun send(bytes: ByteArray): Boolean {
        val api = messageApi ?: return false
        val node = currentNode ?: return false
        for (name in SEND_METHODS) {
            val result = invoke(api, name, arrayOf(String::class.java, ByteArray::class.java), node, bytes)
            if (result != INVOKE_FAILED) {
                // Task<Void>：挂失败监听把真实原因（签名不一致/未授权/未安装）记入 lastError
                attachTaskFailure(result) { e ->
                    lastError = "sendMessage 失败: ${e.message}"
                    Log.w(TAG, lastError ?: "")
                }
                return true
            }
        }
        lastError = "sendMessage 调用失败（无匹配签名）"
        return false
    }

    /** 返回缓存值；真值由 [queryInstallState] 异步刷新（UI 点「刷新连接状态」可见）。 */
    override fun wearAppInstallState(): String = installState

    /** 异步查询手环端快应用安装状态：`Task<Boolean> isWearAppInstalled(nodeId)`。 */
    private fun queryInstallState(nodeId: String) {
        val api = nodeApi ?: return
        val task = invoke(api, "isWearAppInstalled", arrayOf(String::class.java), nodeId)
        if (task == INVOKE_FAILED) return
        attachTaskSuccess(task) { v ->
            installState = if (v == true) {
                BandAdapterDefaults.STATE_INSTALLED
            } else {
                BandAdapterDefaults.STATE_NOT_INSTALLED
            }
        }
        attachTaskFailure(task) { installState = BandAdapterDefaults.STATE_UNKNOWN }
    }

    override fun diagnose(): Map<String, Any?> = mapOf(
        "adapter" to "xms",
        "available" to available,
        "nodeId" to currentNode,
        "nodeCount" to lastNodeCount,
        "discovering" to discovering,
        "permissionGranted" to permissionGranted,
        "installState" to installState,
        "lastError" to lastError,
    )

    // ── 内部实现 ──────────────────────────────────────────────

    /** 初始化 NodeApi / AuthApi / MessageApi（三个静态工厂）+ 注册服务连接监听。 */
    private fun ensureApis() {
        if (nodeApi == null) nodeApi = staticCall(CLS_WEARABLE, "getNodeApi", context)
        if (authApi == null) authApi = staticCall(CLS_WEARABLE, "getAuthApi", context)
        if (messageApi == null) messageApi = staticCall(CLS_WEARABLE, "getMessageApi", context)
        if (serviceApi == null) serviceApi = staticCall(CLS_WEARABLE, "getServiceApi", context)
        registerServiceListener()
    }

    /**
     * 注册「与小米运动健康服务连接」的监听。
     *
     * 这是此前遗漏的一环：`NodeApi.getConnectedNodes()` 依赖 SDK 与手机端
     * 小米运动健康（`com.xiaomi.wearable` / `com.mi.health`）的 Binder 服务连接；
     * 服务未连上时该调用会失败或返回空列表，表现为「一直连接中」。
     * 注册后可在服务就绪时立刻重新发现节点，并在断开时清理状态。
     */
    private fun registerServiceListener() {
        val api = serviceApi ?: return
        if (serviceListenerProxy != null) return
        val iface = try {
            Class.forName("com.xiaomi.xms.wearable.service.OnServiceConnectionListener")
        } catch (e: Throwable) {
            lastError = "找不到 OnServiceConnectionListener: ${e.message}"
            return
        }
        val proxy = try {
            Proxy.newProxyInstance(iface.classLoader, arrayOf(iface)) { _, method, _ ->
                when (method.name) {
                    "onServiceConnected" -> {
                        Log.i(TAG, "小米穿戴服务已连接，开始发现节点")
                        lastError = "服务已连接，正在发现手环节点"
                        discoverInflight = false
                        if (discovering) discoverNodeAsync()
                    }
                    "onServiceDisconnected" -> {
                        Log.w(TAG, "小米穿戴服务已断开")
                        lastError = "小米穿戴服务断开（请确认小米运动健康在运行）"
                        currentNode = null
                        lastNodeCount = -1
                        listenerProxy = null
                        if (discovering) scheduleDiscoveryRetry()
                    }
                }
                null
            }
        } catch (e: Throwable) {
            lastError = "创建服务监听失败: ${e.message}"
            return
        }
        serviceListenerProxy = proxy
        val r = invoke(api, "registerServiceConnectionListener", arrayOf(iface), proxy)
        if (r == INVOKE_FAILED) {
            serviceListenerProxy = null
            lastError = "registerServiceConnectionListener 调用失败"
            Log.w(TAG, lastError ?: "")
        }
    }

    /**
     * 注册消息监听。官方签名（v1.4 AAR 实测）：
     * `Task<Void> addListener(String nodeId, OnMessageReceivedListener listener)`
     * —— 必须带 nodeId，且方法名是 **addListener**（不存在 registerMessageReceivedListener）。
     */
    private fun registerListener(nodeId: String, listener: BandMessageListener) {
        val api = messageApi ?: return
        if (listenerProxy != null) return
        val iface = try {
            Class.forName(CLS_MSG_LISTENER)
        } catch (e: Throwable) {
            lastError = "找不到 OnMessageReceivedListener: ${e.message}"
            Log.w(TAG, lastError ?: "")
            return
        }
        val proxy = try {
            Proxy.newProxyInstance(iface.classLoader, arrayOf(iface)) { _, method, args ->
                try {
                    if (method.name == "onMessageReceived" && args != null && args.size >= 2) {
                        val bytes = args[1] as? ByteArray
                        if (bytes != null) {
                            listener.onMessage(String(bytes, Charsets.UTF_8))
                        }
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "onMessageReceived 处理异常: ${e.message}")
                }
                null
            }
        } catch (e: Throwable) {
            lastError = "创建监听代理失败: ${e.message}"
            Log.w(TAG, lastError ?: "")
            return
        }

        listenerProxy = proxy
        // 官方形态：addListener(String, Listener)
        val task = invoke(
            api, "addListener",
            arrayOf(String::class.java, iface), nodeId, proxy
        )
        if (task == INVOKE_FAILED) {
            lastError = "addListener 调用失败（签名不匹配）"
            listenerProxy = null
            Log.w(TAG, lastError ?: "")
            scheduleDiscoveryRetry()
            return
        }
        // Task 失败（签名不一致 / 未授权 / 未安装）时记录真实原因，便于诊断
        attachTaskFailure(task) { e ->
            listenerProxy = null
            lastError = "addListener 失败: ${e.message}"
            Log.w(TAG, lastError ?: "")
            scheduleDiscoveryRetry()
        }
        Log.i(TAG, "addListener ok, node=$nodeId")
    }

    /** 反注册：官方 `Task<Void> removeListener(String nodeId)`（只收 nodeId，不接 listener）。 */
    private fun unregisterListener() {
        val api = messageApi
        val node = currentNode
        listenerProxy = null
        if (api == null || node == null) return
        val result = invoke(api, "removeListener", arrayOf(String::class.java), node)
        if (result == INVOKE_FAILED) {
            Log.w(TAG, "removeListener 调用失败（不影响功能）")
        }
    }

    /** 发现已连接节点：兼容「同步返回 List」与「返回 Task<List>（getResult 立即取值）」两种形态。 */
    private fun discoverNode(): String? {
        val api = nodeApi ?: return null
        val result = invoke(api, "getConnectedNodes", emptyArray(), *emptyArray())
        if (result == INVOKE_FAILED || result == null) return null

        val nodes: List<Any> = when {
            result is Iterable<*> -> result.filterNotNull()
            result is Array<*> -> result.filterNotNull()
            else -> unwrapTaskList(result)
        }
        for (node in nodes) {
            val id = nodeIdOf(node)
            if (!id.isNullOrEmpty()) return id
        }
        return null
    }

    private fun nodeIdOf(node: Any): String? {
        if (node is String) return node
        // Node.id 是公有字段（AAR 实测），优先按字段取
        try {
            val f = node.javaClass.getField("id")
            val v = f.get(node)
            if (v is String && v.isNotEmpty()) return v
        } catch (e: Throwable) {
            // 继续尝试方法形态
        }
        for (name in NODE_ID_METHODS) {
            val v = invoke(node, name, emptyArray(), *emptyArray())
            if (v is String && v.isNotEmpty()) return v
        }
        return null
    }

    /** Task 形态：尝试同步 getResult()；失败返回空列表（交由轮询重试）。 */
    private fun unwrapTaskList(task: Any): List<Any> {
        return try {
            val m = task.javaClass.getMethod("getResult")
            val v = m.invoke(task)
            when (v) {
                is Iterable<*> -> v.filterNotNull()
                is Array<*> -> v.filterNotNull()
                else -> emptyList()
            }
        } catch (e: Throwable) {
            emptyList()
        }
    }

    /**
     * 校验 DEVICE_MANAGER 权限；未授予则发起授权请求。
     * 官方签名：`Task<Boolean> checkPermission(nodeId, Permission)`、
     * `Task<Permission[]> requestPermission(nodeId, Permission...)` —— 全异步，结果回写 permissionGranted。
     */
    private fun requestPermissionAsync(nodeId: String) {
        val api = authApi ?: return
        try {
            val permClass = Class.forName(CLS_PERMISSION)
            val dm = permissionConstant(permClass) ?: return
            val checkTask = invoke(
                api, "checkPermission",
                arrayOf(String::class.java, permClass), nodeId, dm
            )
            if (checkTask == INVOKE_FAILED) {
                lastError = "checkPermission 调用失败（签名不匹配）"
                return
            }
            attachTaskSuccess(checkTask) { v ->
                if (v == true) {
                    permissionGranted = true
                    Log.i(TAG, "DEVICE_MANAGER 已授权")
                } else {
                    requestPermission(nodeId, permClass, dm)
                }
            }
            attachTaskFailure(checkTask) {
                requestPermission(nodeId, permClass, dm)
            }
        } catch (e: Throwable) {
            lastError = "权限处理失败: ${e.message}"
            Log.w(TAG, lastError ?: "")
        }
    }

    /** 发起授权请求（varargs 签名需构造 Permission[]）。 */
    private fun requestPermission(nodeId: String, permClass: Class<*>, dm: Any) {
        val api = authApi ?: return
        try {
            val arrayCls = java.lang.reflect.Array.newInstance(permClass, 0).javaClass
            val arr = java.lang.reflect.Array.newInstance(permClass, 1)
            java.lang.reflect.Array.set(arr, 0, dm)
            val task = invoke(
                api, "requestPermission",
                arrayOf(String::class.java, arrayCls), nodeId, arr
            )
            if (task == INVOKE_FAILED) {
                lastError = "requestPermission 调用失败（签名不匹配）"
                Log.w(TAG, lastError ?: "")
                return
            }
            lastError = "已发起设备互联授权，请在手机通知栏/弹窗中允许"
            Log.i(TAG, lastError ?: "")
            attachTaskSuccess(task) {
                val again = invoke(
                    api, "checkPermission",
                    arrayOf(String::class.java, permClass), nodeId, dm
                )
                attachTaskSuccess(again) { v ->
                    permissionGranted = (v == true)
                    Log.i(TAG, "授权后 permissionGranted=$permissionGranted")
                }
            }
            attachTaskFailure(task) { e ->
                lastError = "授权失败: ${e.message}"
                Log.w(TAG, lastError ?: "")
            }
        } catch (e: Throwable) {
            lastError = "requestPermission 异常: ${e.message}"
        }
    }

    /** 给 Task 挂成功监听：回调参数即 Task.getResult()。 */
    private fun attachTaskSuccess(task: Any?, onSuccess: (Any?) -> Unit) {
        if (task == null || task == INVOKE_FAILED) return
        try {
            val m = task.javaClass.methods.firstOrNull {
                it.name == "addOnSuccessListener" &&
                    it.parameterTypes.size == 1 &&
                    it.parameterTypes[0].isInterface
            } ?: return
            val iface = m.parameterTypes[0]
            val proxy = Proxy.newProxyInstance(iface.classLoader, arrayOf(iface)) { _, method, args ->
                if (method.name == "onSuccess") {
                    try {
                        onSuccess(args?.firstOrNull())
                    } catch (e: Throwable) {
                        Log.w(TAG, "success 回调异常: ${e.message}")
                    }
                }
                null
            }
            m.invoke(task, proxy)
        } catch (e: Throwable) {
            Log.w(TAG, "挂成功监听失败: ${e.message}")
        }
    }

    /** 给 Task 挂失败监听（拿到真实异常：签名不一致 / 未授权 / 未安装）。 */
    private fun attachTaskFailure(task: Any?, onFailure: (Exception) -> Unit) {
        if (task == null || task == INVOKE_FAILED) return
        try {
            val m = task.javaClass.methods.firstOrNull {
                it.name == "addOnFailureListener" &&
                    it.parameterTypes.size == 1 &&
                    it.parameterTypes[0].isInterface
            } ?: return
            val iface = m.parameterTypes[0]
            val proxy = Proxy.newProxyInstance(iface.classLoader, arrayOf(iface)) { _, method, args ->
                if (method.name == "onFailure") {
                    val e = args?.firstOrNull() as? Exception ?: Exception("unknown")
                    try {
                        onFailure(e)
                    } catch (inner: Throwable) {
                        Log.w(TAG, "failure 回调异常: ${inner.message}")
                    }
                }
                null
            }
            m.invoke(task, proxy)
        } catch (e: Throwable) {
            Log.w(TAG, "挂失败监听失败: ${e.message}")
        }
    }

    /** 取 `Permission.DEVICE_MANAGER`（枚举常量或静态字段）。 */
    private fun permissionConstant(permClass: Class<*>): Any? {
        return try {
            permClass.getField("DEVICE_MANAGER").get(null)
        } catch (e: Throwable) {
            try {
                val valueOf = permClass.getMethod("valueOf", String::class.java)
                valueOf.invoke(null, "DEVICE_MANAGER")
            } catch (e2: Throwable) {
                lastError = "无法解析 DEVICE_MANAGER: ${e2.message}"
                null
            }
        }
    }

    /** 把 Boolean / Task<Boolean> 统一判定为布尔值（Task 无同步结果时保守返回 false）。 */
    private fun toBoolean(value: Any?): Boolean {
        if (value is Boolean) return value
        if (value == null || value == INVOKE_FAILED) return false
        return try {
            val m = value.javaClass.getMethod("getResult")
            (m.invoke(value) as? Boolean) ?: false
        } catch (e: Throwable) {
            false
        }
    }

    // ── 反射小工具 ────────────────────────────────────────────

    private fun findMethod(target: Any, name: String): Method? =
        target.javaClass.methods.firstOrNull { it.name == name }

    private fun invoke(target: Any, name: String, paramTypes: Array<Class<*>>, vararg args: Any?): Any? {
        return try {
            val m = target.javaClass.getMethod(name, *paramTypes)
            m.invoke(target, *args)
        } catch (e: Throwable) {
            INVOKE_FAILED
        }
    }

    private fun invokeStatic(clsName: String, name: String, paramTypes: Array<Class<*>>, vararg args: Any?): Any? {
        return try {
            val cls = Class.forName(clsName)
            val m = cls.getMethod(name, *paramTypes)
            m.invoke(null, *args)
        } catch (e: Throwable) {
            INVOKE_FAILED
        }
    }

    private fun staticCall(clsName: String, name: String, context: Context): Any? {
        return try {
            val cls = Class.forName(clsName)
            val m = cls.getMethod(name, Context::class.java)
            m.invoke(null, context)
        } catch (e: Throwable) {
            lastError = "$name 调用失败: ${e.message}"
            Log.w(TAG, lastError ?: "")
            null
        }
    }
}
