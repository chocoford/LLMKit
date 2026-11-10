# ExcalidrawZ 接入与联调指南

先保持 App 和 LLMKit 不变，验证新后端兼容现有功能；通过后，再接入 Scheme 并测试新增能力。不要同时修改两端，否则很难判断问题来自后端兼容还是客户端改造。

## 版本与范围

- 旧客户端回归基线：已发布的 ExcalidrawZ 2.5.1。
- 新后端应包含 `4768cfb` 和 `3e36e39`，并完成 V4 的 `CreateAppExecutionCatalogs` 迁移。提交完成不代表已经部署。
- 第二阶段需要本次完整状态层桥接版本的 LLMKit，以及包含 `b87f675` 的 LLMCore。仅有 `7ce4ed0` 的请求 API 或 `df1f51e` 的基础 scope，不包含下述完整恢复／辅助请求保障。第一阶段不要为此升级旧 App 的 SDK。
- 本次只讨论经过 LLMServer 的平台助手和 Optimized BYOK。Basic Direct 是另一条独立客户端路径，不作为此次后端升级的前置条件。

## 第一阶段 保持客户端不变

保持要测试的 App 构建、SDK 依赖锁定和会话数据不变，只切换或更新后端。现有的 `createConversation`、`sendMessage`、续写和重试仍可使用旧 `/chat` 接口，不要求添加 Scheme/Profile 请求字段。

新后端已经把旧请求适配到 App 的执行配置：

- `agentID` 对应保存的助手配置，Prompt 仍由服务端注入。
- 平台请求携带的 Model ID 对应其原有 Profile，按 Dashboard 当前规则鉴权。
- 如果 Dashboard 更换了该 Profile 的模型，缓存的旧 Model ID 仍对应原 Profile，实际执行使用当前模型。
- 本地绘图工具、审批、checkpoint 和画布历史仍由 App 管理。
- 平台积分检查和计费不因兼容适配而取消。

### 回归清单

1. 登录前后模型菜单可加载；登录身份对应正确的 Production 或 Debug App。
2. 新建会话，发送普通问题，检查流式显示和最终回复。
3. 发送绘图请求，检查本地工具执行、画布修改、审批和 checkpoint。
4. 同一会话继续对话，重新打开旧会话，执行重试、停止和撤销。
5. 检查附件、标题生成、摘要压缩和会话持久化。
6. 检查积分变化、余额不足和订阅不足时的提示。
7. 如果当前待测构建已经支持 Optimized BYOK，再测试它的现有流程；不要把尚未接入的 Basic Direct 或 Scheme 当成回归失败。

第一阶段的问题先定位到旧调用兼容，不同时改写 App 的调用链。建议记录 App 构建号、账号环境、请求路径、request-id、会话 ID 和异常步骤；不要记录 API Key 或完整认证头。

### 已知旧行为

2.5.1 的客户端枚举 `extraHigh` 与服务端 Profile ID `extra-high` 存在历史不一致。这一版没有为旧客户端修复菜单映射；第一阶段不要以“旧 App 必须新增显示 Extra High”为通过条件。

旧平台 `/chat/stream` 保持原来的 SSE 与 EOF 收尾行为。严格 `[DONE]` 校验是新 Scheme/BYOK 路径的测试要求，不应套在 2.5.1 的旧平台流上。

## 第二阶段 接入 Scheme

第一阶段通过后，再升级客户端 SDK 并接入新调用。核心变化是从“传 Model ID，让后端推断档位”改成“传 Scheme ID 和 Profile ID，由后端选择模型”。

`excalidraw-canvas` 是目前导入的 Scheme 数据 ID，不是 LLMKit 内置功能类型。客户端需要知道自己使用哪个 Scheme；具体名称、模型选项、Prompt 和订阅条件由 Dashboard 配置。

### 动态模型菜单

```swift
import LLMCore
import LLMKit

// 放在已有 async 方法中。client 使用 App 现有的认证配置。
let scheme = try await client.getScheme(id: "excalidraw-canvas")
let options = scheme.profiles
    .filter(\.isVisible)
    .sorted { $0.rank < $1.rank }
```

菜单使用 `profile.id`、`name`、`rank`、`capabilities` 和 `access`，不再依赖固定的四档枚举，也不再读取 `requirements.plan == "max"`。

- Profile ID 按服务端原样保存，例如 `extra-high`，不要转换成 `extraHigh`。
- `access` 是平台调用的提示快照，不是授权凭证；服务端在执行时重新鉴权。
- 登录、退出、购买或恢复订阅、切换环境后刷新菜单与访问状态。
- Profile 被删除或访问被拒绝时，明确提示，不自动切换到其他模型、计费模式或后端。
- 对话保存 Scheme/Profile 选择；不要再从模型字符串反推档位。SDK 的 `Conversation.schemeConnection` 保存非敏感路由，App 自定义会话存储必须保留这个字段，不要求改 LLMCore。

### 先验证请求 API

以下接口已经存在，可用于单次请求或流式联通测试：

```swift
let stream = try await client.streamScheme(
    .init(schemeID: "excalidraw-canvas", profileID: "high"),
    billing: .platform,
    messages: [.init(role: .user, content: "你好")],
    metadata: EmptyMetadata()
)

for try await event in stream {
    // 将事件交给测试界面；这里不会自动执行本地工具。
    switch event {
    case .message: break
    case .settlement: break
    }
}
```

平台计费显式使用 `.platform`。SDK 不读取用户服务商 Key；后端按选择的 Profile 决定实际模型。

### 接入现有工具和会话状态

`LLMSchemeProvider` 已经能接到现有 `AgentExecutor`：

```swift
let provider = LLMSchemeProvider(
    client: client,
    selection: .init(schemeID: "excalidraw-canvas", profileID: "high"),
    billing: .platform
)
let executor = AgentExecutor(llmProvider: provider, toolRegistry: toolRegistry)
```

`LLMState` 和 `LLMStateObject` 已复用同一套可选路由桥接。不是给现有方法增加 `scheme:` 参数，也不是只修改交易 metadata。用 `withScheme` 新建会话：

```swift
try await client.withScheme(
    .init(schemeID: "excalidraw-canvas", profileID: selectedProfileID),
    billing: .platform
) {
    try await llmState.createConversation(
        id: conversationID,
        model: selectedModelHint, // 兼容参数；实际模型仍由服务端 Profile 决定
        agentConfig: agentConfig, // agentID 为空或等于 Scheme ID，保留本地工具
        messages: [.content(.init(role: .user, content: prompt))]
    )
}
```

新建时保存 `Conversation.schemeConnection`；省略平台 Profile 时先解析默认 Profile，并保存具体 ID。之后直接调用现有 `sendMessage`、`regenerateMessage`、`resumeGeneration`、`compactConversation`，SDK 自动沿用保存的路由，不读取当前菜单来覆盖历史选择。

用户在同一会话中显式换档位时，在空闲状态更新模型选择，再发送下一条消息：

```swift
try await llmState.updateSchemeConnection(
    .init(selection: .init(schemeID: "excalidraw-canvas", profileID: newProfileID), billing: .platform),
    in: conversationID
)
```

同一 BYOK 连接也可用这个方法更换 `billing: .byok(model:)`，保持原 `connectionID`。此方法不能切换 Scheme、计费来源或连接身份；这些变更仍需新建会话。它只保存用户选择，不代表获准使用；下一次生成仍重新鉴权。生成期间拒绝换模型，写入失败保留旧选择。

Optimized BYOK 新建时使用 `billing: .byok(model: selectedModel)` 和稳定的 `connectionID`，不传平台 Profile。首次 `withScheme` 仍从 client 的凭据回调取 Key，因此应放在 App 对该连接固定的 `withSelectedBilling` 范围内。为后续发送／恢复，在状态初始化时注入按 ID 查询的回调：

```swift
let llmState = LLMState(
    llmClient: client,
    toolRegistry: toolRegistry,
    persistenceProvider: persistenceProvider,
    schemeCredentialsProvider: { connectionID, model in
        // App 实现：按保存的 ID 查连接配置和 Keychain，不读当前选中的连接。
        try await credentialStore.credentials(connectionID: connectionID, model: model)
    }
)
```

此回调返回非可选 `LLMBYOKCredentials`。连接删除、Key 缺失或配置不兼容时抛错；没有回调也明确失败，不读取其他连接或回退平台。

桥接保障与边界：

1. 无 `schemeConnection` 且未显式使用 scope 的旧会话仍走旧接口。App 可显式包裹 `withScheme` 操作旧会话，但 SDK 不自动推断或持久化迁移其路由。
2. 单次生成固定 Scheme、Profile、计费和凭据，覆盖工具轮次和超限压缩后的自动重试。手动重试／恢复是新生成，按原路由重新取 Key、重新预检。
3. 上传、重试删除历史等副作用前，按真实 Scheme/Profile 与计费来源检查 `/access/evaluate`；App 还能额外提供本地 accessPolicy。服务端执行时仍重新鉴权，预检不是授权凭证。
4. 标题／摘要使用同一计费和凭据快照，但仍是独立辅助请求，不注入绘图 Scheme 的 Prompt 或执行绘图工具。BYOK 默认使用聊天模型，可配置同连接辅助模型；平台保留原辅助模型选择。
5. 保留上传、流式更新、持久化、审批、取消、错误清理、压缩和 App 的 checkpoint／撤销。冲突的 Scheme/Profile/计费/连接 scope 报错，不隐式覆盖已绑定会话；会话内换模型使用上述显式更新入口。
6. 只保存选择与连接 ID，绝不保存 Key。自定义 Core Data／SQLite／文档存储必须保留并恢复可选 `schemeConnection`；旧记录缺字段按 nil 读取。非整份 Codable 存储需要 App 补字段映射和自己的存储迁移。SDK 没有修改原 `PersistenceProvider` 协议或 LLMCore。若要支持已保存会话换模型，存储实现还需遵循可选子协议 `LLMSchemeConversationPersistenceProvider`，用 `updateSchemeConnection(_:in:)` 原子更新既有记录的路由字段；未升级的实现仍可聊天，但换模型会明确报错，不会只改内存而丢失持久化。

### Optimized BYOK

继续复用 App 已有的 Keychain 与凭据回调。需要 LLMServer 身份认证，服务商 Key 按请求经过后端但不保存；模型调用不扣平台积分，本地/平台工具的独立费用与权限仍可能适用。

```swift
let stream = try await client.streamScheme(
    .init(schemeID: "excalidraw-canvas"), // BYOK 不传平台 profileID
    billing: .byok(model: .other(selectedModelID)),
    messages: [.init(role: .user, content: "你好")],
    metadata: EmptyMetadata()
)
```

- 首次绑定、直接调用请求 API 或操作未绑定旧会话时，仍使用 App 的 `withSelectedBilling` 快照。已绑定会话由 SDK 根据保存的路由及 `schemeCredentialsProvider` 管理生成快照。
- 缺失 Key 应抛错；不要返回 nil 并静默转成平台付费。
- 模型列表通过 `listBYOKModels` 查询，仅作提示，允许手动输入合法 ID。
- `getScheme` 返回的逐 Profile `access` 是平台权限，不用它判断 BYOK 权限。BYOK 检查独立的 `inference/chat` BYOK 门槛，不叠加 Canvas／平台模型的订阅条件，也不带平台 Profile ID。Scheme 必须可用；共同的禁用规则、App 资源绑定和显式 BYOK 访问规则仍然生效。
- 自定义域名要接收服务器私有 Prompt，仍需 `LLM_BYOK_TRUSTED_AGENT_HOSTS` 批准；HTTPS、公网地址和 DNS 安全检查仍然生效。
- SDK 向后端发送 Key 时仅允许 HTTPS，开发例外是本机 loopback HTTP；普通局域网 HTTP 地址不在例外内。

Basic Direct 不使用这些 Scheme API。它需要独立 Direct client、本地基础 Prompt、`agentID == nil` 和本地工具；不能把当前服务端 ExcalidrawAgentConfig 原样搬过去，也不能失败后回退后端。

## Dashboard 联调配置

先确认选对 App：正式包通常是 `com.chocoford.excalidraw`，Debug 包是 `com.chocoford.excalidraw-Debug`。以当前认证身份所属的 App 记录为准。

在 **Capabilities → Model Access** 中：

1. 保留导入的 Excalidraw Canvas Scheme 与现有策略，先完成第一阶段回归。
2. 联调“普通助手可用、Extra High 付费”时，Scheme 允许所有已登录用户，给 `extra-high` 增加所需订阅条件。父级与子级条件对平台调用同时生效，不限制 Optimized BYOK。
3. 订阅产品选择这个 App 已注册的实际 Product ID，不引入新的通用 Starter/Max 套餐定义。
4. Optimized BYOK 单独开启并配置条件；只有助手允许访问，不代表 BYOK 自动获准。其订阅条件与平台助手独立，例如平台要求某产品时，BYOK 仍可允许其他产品或所有已登录用户；但 Scheme 本身不能禁用。
5. Web Search 等平台工具有独立条件，开启也不会自动给 App 注册 MCP 工具。

生产 Server 只认可 Production 订阅证据；本地非生产环境可接受 Sandbox/Xcode。用测试订阅联调时，避免把环境不匹配误判为客户端权限 Bug。

## 第二阶段验收

- 新聊天日志中的请求路径是 `/schemes/stream`，Optimized BYOK 是 `/schemes/byok/stream`，不再只是在 metadata 中出现 Profile ID。
- Dashboard 新增第五档，客户端无需改枚举即可显示并选择。
- 修改 Profile 模型后，客户端仍传相同 Profile ID；实际模型由服务端解析。
- 普通账号不能使用受限档位；符合 Dashboard 条件的账号可以使用；App 本地篡改菜单不能绕过服务端。
- 多轮工具、审批、checkpoint、撤销、重试、恢复生成、附件、标题、摘要和持久化均通过。
- 部分回答后断流、损坏 SSE、缺少 `[DONE]` 时抛错，不执行半截工具参数；停止后不再继续执行工具。
- BYOK 缺 Key、服务商拒绝、模型不存在时明确失败，不切到平台模型；平台积分不足不应阻止纯 BYOK 模型推理，但平台工具单独检查。
- 从旧会话恢复时，不静默改为另一个 Scheme/Profile/计费模式；需要变更时由用户明确选择。

## 建议交接顺序

先交付第一阶段回归结果，再升级包含完整状态层桥接的 LLMKit，最后改 ExcalidrawZ 动态菜单、首次绑定和凭据恢复／存储映射。第二阶段重跑第一阶段的全部用例，确保新接入没有破坏原有画布和会话能力。

客户端改造主要涉及 App 里的 `ExcalidrawZApp.swift`、`AIInferenceBillingState.swift`、`ExcalidrawModelProfileOption.swift`、模型菜单加载、新建/发送入口和重试入口。不要为了接入而重写 LLMCore 的 AgentExecutor 或套餐协议。
