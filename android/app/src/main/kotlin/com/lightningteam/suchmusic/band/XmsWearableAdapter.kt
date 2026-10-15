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
        private const val CLS_PERMISSION = "com.xiaomi.xms.wearable.Permission"
        private const val CLS_MSG_LISTENER =
            "com.xiaomi.xms.wearable.message.OnMessageReceivedListener"

        /** 节点 id 取值候选方法名 */
        private val NODE_ID_METHODS = arrayOf("getId", "getNodeId", "id")

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
            registerListener(listener)
            val node = discoverNode()
            if (node != null) {
                currentNode = node
                permissionGranted = checkPermission(node)
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
                // 返回值可能为 Task / Boolean，均视为「已受理」
                return true
            }
        }
        lastError = "sendMessage 调用失败（无匹配签名）"
        return false
    }

    override fun wearAppInstallState(): String {
        val api = nodeApi ?: return BandAdapterDefaults.STATE_UNKNOWN
        val node = currentNode ?: return BandAdapterDefaults.STATE_UNKNOWN
        // 先试带参 isWearAppInstalled(nodeId)，再试无参变体
        val withArg = invoke(api, "isWearAppInstalled", arrayOf(String::class.java), node)
        val raw = if (withArg != INVOKE_FAILED) withArg
        else invoke(api, "isWearAppInstalled", emptyArray(), *emptyArray())
        return when (raw) {
            is Boolean -> if (raw) BandAdapterDefaults.STATE_INSTALLED else BandAdapterDefaults.STATE_NOT_INSTALLED
            else -> BandAdapterDefaults.STATE_UNKNOWN
        }
    }

    override fun diagnose(): Map<String, Any?> = mapOf(
        "adapter" to "xms",
        "available" to available,
        "nodeId" to currentNode,
        "permissionGranted" to permissionGranted,
        "lastError" to lastError,
    )

    // ── 内部实现 ──────────────────────────────────────────────

    /** 初始化 NodeApi / AuthApi / MessageApi（三个静态工厂）。 */
    private fun ensureApis() {
        if (nodeApi == null) nodeApi = staticCall(CLS_WEARABLE, "getNodeApi", context)
        if (authApi == null) authApi = staticCall(CLS_WEARABLE, "getAuthApi", context)
        if (messageApi == null) messageApi = staticCall(CLS_WEARABLE, "getMessageApi", context)
    }

    /** 通过动态代理实现 `OnMessageReceivedListener`，收到消息后回调 Rust 侧监听器。 */
    private fun registerListener(listener: BandMessageListener) {
        val api = messageApi ?: return
        if (listenerProxy != null) return
        val proxy = try {
            val iface = Class.forName(CLS_MSG_LISTENER)
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
            null
        } ?: return

        listenerProxy = proxy
        var registered = false
        for (name in ADD_LISTENER_METHODS) {
            val candidate = findMethod(api, name)
            if (candidate != null) {
                val paramTypes = candidate.parameterTypes
                if (paramTypes.isNotEmpty() && paramTypes[0].isInstance(proxy)) {
                    if (invoke(api, name, arrayOf(paramTypes[0]), proxy) != INVOKE_FAILED) {
                        registered = true
                        break
                    }
                }
            }
        }
        if (!registered) {
            // 也存在挂到 Wearable 上的写法，最后尝试一次
            for (name in ADD_LISTENER_METHODS) {
                if (invokeStatic(CLS_WEARABLE, name, arrayOf(proxy.javaClass.interfaces.first()), proxy) != INVOKE_FAILED) {
                    registered = true
                    break
                }
            }
        }
        if (!registered) lastError = "注册消息监听失败（无匹配方法）"
    }

    private fun unregisterListener() {
        val api = messageApi
        val proxy = listenerProxy ?: return
        if (api != null) {
            for (name in arrayOf("removeMessageReceivedListener", "unregisterMessageReceivedListener", "removeListener")) {
                val m = findMethod(api, name) ?: continue
                if (m.parameterTypes.isNotEmpty() && m.parameterTypes[0].isInstance(proxy)) {
                    invoke(api, name, arrayOf(m.parameterTypes[0]), proxy)
                    break
                }
            }
        }
        listenerProxy = null
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

    /** 申请 / 校验 DEVICE_MANAGER 权限。返回值可能为 Boolean 或 Task<Boolean>。 */
    private fun checkPermission(nodeId: String): Boolean {
        val api = authApi ?: return false
        return try {
            val permClass = Class.forName(CLS_PERMISSION)
            val deviceManager = permissionConstant(permClass) ?: return false
            val check = invoke(
                api, "checkPermission",
                arrayOf(String::class.java, permClass), nodeId, deviceManager
            )
            if (toBoolean(check)) return true
            // 未授予 → 请求授权（可能弹系统授权面板）
            val requested = invoke(
                api, "requestPermission",
                arrayOf(String::class.java, permClass), nodeId, deviceManager
            )
            toBoolean(requested)
        } catch (e: Throwable) {
            lastError = "权限处理失败: ${e.message}"
            Log.w(TAG, lastError ?: "")
            false
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
