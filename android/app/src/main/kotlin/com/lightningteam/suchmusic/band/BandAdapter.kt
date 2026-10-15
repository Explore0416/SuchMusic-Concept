package com.lightningteam.suchmusic.band

/**
 * 手环底层通信适配层（薄）。
 *
 * **为什么要抽象这一层**：小米官方 `xms-wearable-lib`（`com.xiaomi.xms.wearable.*`）
 * 因**专有许可不能随仓库分发**。因此：
 * 1. 对 SDK 的全部调用都收敛到本接口的实现里；
 * 2. 真机实现 [XmsWearableAdapter] 一律通过**反射**访问 `com.xiaomi.xms.wearable.*`，
 *    不产生编译期硬依赖；
 * 3. 兜底实现 [NoopBandAdapter] 在 AAR 缺席时返回「SDK 未就绪」的安全值。
 *
 * 这样即便用户本机没有放置该 AAR，Android 侧也能正常编译、构建 APK。
 *
 * 设计原则（与既有 `SoundEffectBridge` / `IslandBridge` 一致）：
 * **尽力而为，任何失败静默降级**，绝不把异常抛给 Flutter。
 */
interface BandAdapter {

    /** SDK 是否就绪（运行时可加载 `com.xiaomi.xms.wearable.Wearable`）。 */
    fun isAvailable(): Boolean

    /**
     * 启动链路：发现已连接的手环节点 → 申请 `DEVICE_MANAGER` 权限 → 注册消息监听。
     *
     * @return true 表示已成功发现节点并完成监听注册；false 表示暂不可用（调用方按退避重试）。
     */
    fun start(listener: BandMessageListener): Boolean

    /** 停止链路：注销监听、释放资源（异常静默）。 */
    fun stop()

    /** 发送一帧 UTF-8 字节到当前节点；成功返回 true。 */
    fun send(bytes: ByteArray): Boolean

    /**
     * 手环端快应用是否已安装：`installed` / `not_installed` / `unknown`。
     *
     * SDK 不提供确定结论时返回 `unknown`（UI 显示「未知」并说明原因）。
     */
    fun wearAppInstallState(): String

    /** 当前连接的手环节点 id（无则 null）。 */
    fun currentNodeId(): String?

    /** 诊断信息（真机定位用，键值均为可安全跨通道传输的原始类型）。 */
    fun diagnose(): Map<String, Any?>
}

/** 手环上行消息回调：参数为 UTF-8 解码后的原始信封 JSON 字符串。 */
fun interface BandMessageListener {
    fun onMessage(text: String)
}
