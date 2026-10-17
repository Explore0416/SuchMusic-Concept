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
    private var listenerProxy: Any? = null
    private var currentNode: String? = null
    private var permissionGranted = false
    private var available = false
    private var lastError: String? = null
    private var installState: String = BandAdapterDefaults.STATE_UNKNOWN

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

    override fun start(listener: BandMessageListener): Boolean {
        if (!available) return false
        return try {
            ensureApis()
            // 顺序很关键：官方 API 是 addListener(nodeId, listener)，
            // 必须先发现节点拿到 nodeId，才能注册消息监听。
            val node = discoverNode()
            if (node != null) {
                currentNode = node
                registerListener(node, listener)
                requestPermissionAsync(node)
                queryInstallState(node)
                return true
            }
            lastError = "未发现已连接的手环节点"
            false
        } catch (e: Throwable) {
            lastError = e.message
            Log.w(TAG, "start 失败: ${e.message}")
            false
        }
    }

    override fun stop() {
        unregisterListener()
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
        "permissionGranted" to permissionGranted,
        "installState" to installState,
        "lastError" to lastError,
    )

    // ── 内部实现 ──────────────────────────────────────────────

    /** 初始化 NodeApi / AuthApi / MessageApi（三个静态工厂）。 */
    private fun ensureApis() {
        if (nodeApi == null) nodeApi = staticCall(CLS_WEARABLE, "getNodeApi", context)
        if (authApi == null) authApi = staticCall(CLS_WEARABLE, "getAuthApi", context)
        if (messageApi == null) messageApi = staticCall(CLS_WEARABLE, "getMessageApi", context)
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
            return
        }
        // Task 失败（签名不一致 / 未授权 / 未安装）时记录真实原因，便于诊断
        attachTaskFailure(task) { e ->
            lastError = "addListener 失败: ${e.message}"
            Log.w(TAG, lastError ?: "")
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
