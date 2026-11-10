# LLMKit

LLMKit is a SwiftUI framework for integrating Large Language Model functionality with a clean and intuitive API.

## How to use

```swift
import SwiftUI
import LLMKit

extension LLMClient {
    static var shared = LLMClient(
        authProvider: .xcode(bundleID: "..."),
        uploadProvider: .default,
        uploadPolicy: .automatic
    )
}

struct LLMPersistenceProvider: PersistenceProvider {...}

@main
struct MyApp: App {
    let persistenceController = LLMPersistenceProvider()
  
    var body: some Scene {
        WindowGroup {
            ContentView()
                .llmProvider(
                    client: .shared,
                    persistenceProvider: persistenceController
                )
        }
    }
}
```

## BYOK Direct (no LLMServer)

Select Direct explicitly when the App should connect to the user's model service without
platform login, credits, uploads or private server Domain Agent prompts:

```swift
let client = LLMClient(
    directBYOK: LLMBYOKProvider(configuration: .openAI, apiKeyProvider: readAPIKey),
    options: .init(systemPrompt: "Your App-owned basic drawing instructions")
)
let models = try await client.listBYOKModels() // advisory; manual IDs remain valid
let response = try await client.chat(model: .other(selectedModelID), text: "Draw a flowchart")
let agent = AgentConfig.withTools(["draw", "checkpoint"], systemPrompt: "Use the registered local tools.")
// Register the App's local Tool implementations and use this client/agent with LLMState.
// Keep agentID nil: server Domain Agents are intentionally unavailable in Direct.
```

Direct reuses the same presets/custom HTTPS configurations, model aliases and native tool
schemas. The App owns key storage, local prompts and tool execution; the service bills the
user. No Direct error retries with LLMServer, platform credentials or another model.
Streaming requires valid frames, complete tool arguments, a successful finish reason and
the configured upstream completion marker. Cancelling the consumer stops the HTTP request.

Titles and summaries use the same connection. Model precedence is
`LLMDirectOptions.auxiliaryModel`, then `configuration.options.auxiliaryModel`, then the chat
model. Auxiliary requests do not inherit the drawing system prompt. Images are prepared
inline (or retained as existing HTTPS URLs), never uploaded to LLMServer/R2 by Direct.
Generated image/audio output and server-backed tools/endpoints return explicit unsupported
errors; the App can supply its own local drawing/image tools instead.

Conversations carry a Codable, non-secret connection configuration and chat-model hint,
never the key. Host persistence should save/restore the full Conversation snapshot, including
the updated hint when changing models. Existing conversations with no Direct binding remain backend conversations. Send,
regenerate, resume and compaction reject a mismatched mode/configuration; start a new
conversation when switching. Use separate clients/states for Direct and enhanced backend
assistants. `inferenceMode`/`isDirectBYOK` let the App select its own UI and access rules.
Requests disable redirects, caching and cookie handling. If you inject a custom URLSession,
its remaining networking/TLS configuration and lifetime are managed by the host App.
Pass a compatible selected model explicitly to `ask`; its existing OpenAI default is not
automatically substituted with a vendor-specific model.

## App-owned access preflight

Pass `accessPolicy: LLMAccessPolicyProvider` to the normal `LLMClient` initializer to check
local feature access before backend inference or image upload. It receives the actual model,
resource and billing source. The App interprets opaque requirement IDs using its own
entitlements; LLMKit has no built-in Starter/Pro/Max hierarchy. For a selected platform profile:

```swift
try await client.authorizeAccess(.init(
    resource: .init(kind: "agent", id: agentID, billingSource: .platform, modelProfileID: profile.id),
    model: profile.model,
    requirementIDs: profile.requirements.requiredAccessIDs
))

// A fresh server-side UI preview, not a permission token:
let decision = try await client.getAccessDecision(for: .init(
    kind: "agent", id: agentID, billingSource: .platform, modelProfileID: profile.id
))
```

The host policy must deny unknown requirements. Without a callback, ordinary inference keeps
relying on authoritative server checks; explicit local requirement checks fail closed.
The server independently derives resources and applies trusted Dashboard/admin rules scoped
to the authenticated App. Neither the callback nor preview can grant server permission.
New local features can use `authorizeAccess` with App-owned resource/requirement IDs.

Handle `LLMError.accessDenied(requirementIDs:)` separately from `.unauthorized` and
`.insufficientCredits`. Legacy non-policy 403 responses remain `.forbidden`; missing server
policy is `.server(statusCode: 503, ...)`, not a payment failure. Consumers with exhaustive
switches over `LLMError` must handle the new case. Direct mode does not query server policies.

## BYOK through LLMServer

There is one configuration-driven `LLMBYOKProvider`. The ready-made `LLMBYOKConfiguration`
presets cover OpenRouter, OpenAI, Anthropic, Google Gemini, DeepSeek, xAI, Mistral, Groq,
Together AI, Moonshot/Kimi, Alibaba Cloud/Qwen, MiniMax and SiliconFlow. They are data,
not separate implementations. New presets reuse OpenAI-compatible chat and model discovery;
no account-scoped management APIs or additional provider adapters are included.
Custom connections use the same API. Requests still go through LLMServer, which retains
Domain Agent prompts, tool policy and chat/SSE. Backend BYOK inference requires App login
and configured App access, but not platform model credits. Advisory model discovery remains
guest-capable. BYOK does not use the
platform model catalog or model-tier subscription gates; the upstream decides model access.

The host app owns key storage (normally Keychain). Pass an async key reader; the SDK reads
it for each inference request and does not persist or encode its result:

```swift
func makeBYOKClient(
    readAPIKey: @escaping @Sendable () async throws -> String
) -> LLMClient {
    LLMClient(
        authProvider: .xcode(bundleID: "com.example.app"),
        byokProvider: LLMBYOKProvider(
            configuration: .openAI, // .openRouter, .anthropic or .gemini
            apiKeyProvider: readAPIKey
        )
    )
}
```

Obtain a valid App token with the existing auth flow before backend BYOK inference. Server
requirements map to the App's registered subscription products in Dashboard; the SDK does
not define a new plan. Model discovery alone needs no App token and creates no account or
credit record. Direct BYOK is separate from this backend authorization mechanism.

Use `LLMBYOKPreset.allCases` and `preset.displayName` to populate a connection menu. Every
preset has a matching configuration convenience, for example `.deepSeek`, `.xAI`, `.groq`,
`.siliconFlow` or `.miniMax`. Moonshot, MiniMax and DashScope have separate China and
international presets (`.moonshotChina`, `.miniMaxChina`, `.dashScopeInternational`);
region-specific keys are not interchangeable; no request retries another region or provider.

The DashScope presets use shared Beijing/Singapore endpoints. Accounts using a recommended
workspace-specific endpoint must edit `baseURL` to the exact API Host shown in their console.
That custom host still requires server approval to receive Domain Agent prompts. These are
ordinary pay-as-you-go API presets, not vendor Coding Plan/subscription-key endpoints.

A custom configuration contains only connection settings and may be saved/synced by the
App. Keys stay separate. `baseURL` is an HTTPS API root; `chat/completions` is appended:

```swift
let configuration = LLMBYOKConfiguration(
    baseURL: URL(string: "https://gateway.example.com/v1/")!,
    defaultModel: "logical-model",
    modelMapping: .init(aliases: ["logical-model": "team/actual-model"]),
    options: .init(includeUsage: false)
)
let provider = LLMBYOKProvider(configuration: configuration) {
    try await readCustomAPIKeyFromKeychain() // Host-app implementation.
}
// Pass byokProvider: provider to LLMClient.
// Then select model: .other("logical-model") when sending a chat request.
```

`defaultModel` is a hint for the host App; it does not silently override existing SDK method
defaults or an explicitly requested model. You can also edit a preset's value-type settings.
Options cover usage frames, output-token limits/parameter, store=false, model aliases,
Google thought signatures and OpenRouter extensions. Inference supports only Chat Completions-compatible APIs
with Bearer-key authentication, not arbitrary native Responses/Messages/Gemini,
extra-header/query authentication or provider-specific image/audio/video APIs. The Anthropic
and Gemini presets use official compatibility endpoints, not OpenRouter. The OpenRouter
preset selects the existing image-response extension for known image variants; other presets
forward those model IDs through the normal chat adapter rather than reject them by name.
This does not add support for native image endpoints or guarantee a model's capabilities.
Nor does a preset add native Responses/Agent APIs or preserve every vendor's separate
reasoning/encrypted-thinking fields across tool rounds. Such models/features need additional
protocol adapters; the generic Chat Completions preset alone is not a compatibility guarantee.

BYOK accepts model IDs not present in `SupportedModel` via `.other("model-id")`. Neither
provider-family prefixes nor the Domain Agent's `modelProfiles` / `allowedModels` are model
admission rules in BYOK mode. Only basic model-ID syntax/size validation remains. Provider
errors are returned without a replacement model or a platform-key retry. Use the user's
connection/model selection in BYOK UI, not the platform model menu or its paid tiers.

### List models for a BYOK connection

```swift
// Uses the client's configured BYOK provider; reads the key for this request only.
let models = try await client.listBYOKModels()
for entry in models {
    print(entry.id, entry.displayName)
    // entry.model is a SupportedModel, including .other(...) for unknown IDs.
}

// Browse an explicit connection without changing the client's provider.
let otherModels = try await client.listBYOKModels(provider: provider)
// Or resolve the connection using the existing model-aware credential callback.
let sameConnectionModels = try await client.listBYOKModels(for: selectedModel)
```

The SDK sends `POST /chat/byok/models` to LLMServer with BYOK credentials, which queries the
selected upstream with the request-only key. It does not run inference, inject prompts,
check/debit credits or create an LLM usage record. Catalog-enabled presets use compatible
model lists; Anthropic uses native `x-api-key` authentication and fetches all pages.
No failure retries with the platform key.

All exposed presets have model discovery configured. MiniMax's China/international presets
reuse standard `GET {baseURL}/models` with Bearer authentication. Fireworks, Z.AI/Zhipu and
Volcengine are deferred from the preset menu until their catalogs can reuse this contract
or additional integration is explicitly added. They have no built-in Domain Agent host
approval; compatible custom connections remain possible under the normal trust rules.

Custom connections default to `GET {baseURL}/models`. Set `modelDiscovery` to
`.init(path: "catalog/models")` for a different relative path, or `nil` to disable it.
Paths cannot change origin or escape the API root. Missing upstream list endpoints return
HTTP 501; disabled local discovery throws `LLMBYOKConfigurationError.modelDiscoveryUnsupported`.
An empty list is distinct from an unsupported query. With a model-aware callback, supply
`provider:` or `for:` explicitly; a no-argument query cannot guess a connection.

This is an advisory upstream catalog, not a whitelist or a guarantee of chat/tools/modality
support. Keep manual model-ID entry available and retain the selected connection alongside
the ID: vendor-native IDs do not identify a provider by themselves.

For multiple keys or dynamic connection selection, use `byokModelCredentialsProvider`:

```swift
func makeMultiProviderClient(
    readAPIKey: @escaping @Sendable (LLMBYOKPreset) async throws -> String
) -> LLMClient {
    LLMClient(
        authProvider: .xcode(bundleID: "com.example.app"),
        byokModelCredentialsProvider: { model in
            let preset: LLMBYOKPreset
            switch model.provider {
            case "OpenAI": preset = .openAI
            case "Anthropic": preset = .anthropic
            case "Google": preset = .gemini
            default: preset = .openRouter
            }
            return LLMBYOKCredentials(
                configuration: preset.configuration,
                apiKey: try await readAPIKey(preset)
            )
        }
    )
}
```

Selection precedence is model-aware callback → `byokProvider` → old zero-argument callback.
A model callback's nil explicitly selects platform billing and does not consult other sources.
If BYOK is selected but the key is missing, throw `LLMBYOKConfigurationError.invalidAPIKey`;
never return nil as a fallback. With all credential sources omitted, platform behavior is
unchanged. The old `LLMBYOKCredentials(provider:apiKey:)` preset initializer remains deprecated;
the former provider enum is now named `LLMBYOKPreset`.

All inference paths, including Agent rounds, temporary chat, `ask`, titles and compaction,
resolve credentials per request. Titles use `options.auxiliaryModel` if configured, otherwise
the BYOK conversation model. Select a compatible `model` / `summaryModel` for `ask` and manual
compaction; their existing OpenAI defaults are unchanged. No model/key fallback is performed.

- An App JWT stays in `Authorization`; backend inference requires it, model discovery does not.
  Key-free config uses `X-LLM-BYOK-Configuration`;
  the model key travels separately in `X-LLM-BYOK-Key`, never the JSON body.
- SDK requests use `/chat/byok`, `/chat/byok/stream`, `/chat/byok/ask` and `/chat/byok/models`. Older servers
  reject unsupported routes/configuration rather than silently billing the platform.
  Keys are never sent to auth, credits, tools, push, search or upload endpoints.
- LLMServer processes the key only in request memory. The BYOK path does not write it to a
  database, conversation, metadata, credit transaction or application log. This is backend
  forwarding, not a mode where the key never leaves the device.
- Custom endpoints must resolve only to public IP addresses. LLMServer pins the checked
  address, verifies TLS against the original host, and disallows redirects/proxies. Custom
  Domain Agent hosts need server approval via `LLM_BYOK_TRUSTED_AGENT_HOSTS`, because they
  receive the server-held prompt; the fixed official hosts of the built-in presets are
  preapproved by the server's installed LLMCore version (not by an App-provided label).
- BYOK model inference does not consume platform model credits; tools/search/uploads retain
  their own authentication/billing rules. Agent registration, endpoint trust and tool policy
  remain. Platform model allowlists and model-tier plan gates apply only in platform mode;
  any separate agent/tool entitlements are not waived by BYOK.
- Provider failures never switch to the platform key. Upstream auth/balance failures use a
  fixed BYOK HTTP 502 error rather than platform logout/recharge behavior.
- SDK BYOK streams always require a complete server `[DONE]` frame. Partial EOF, malformed
  SSE/UTF-8/JSON or invalid response data throws, including after partial text/tool arguments.
  A custom upstream can opt out of its own DONE via `options.requiresDoneMarker=false`,
  but the backend still requires a complete finish frame and the App-side rule never relaxes.

Update LLMCore in LLMServer and the App/LLMKit first, deploy the server, then distribute the
new SDK. The optional `ToolCall.providerMetadata` preserves Gemini thought signatures;
custom persistence and tool sanitizers must retain it. No database migration is needed for
Codable tool JSON. Adjust App send-button credit gating for BYOK if necessary; tools can
still require platform credits. Proxies, APM, tracing and crash reporting must exclude
inbound `X-LLM-BYOK-Key` and outbound provider `Authorization` / `x-api-key` from captured requests.

## Dashboard-managed Schemes

For new server-enhanced features, use stable Scheme/Model Option IDs instead of inferring a
tier from a model ID. Schemes, display names, prompts, image parameter schemas and model menus
are App-owned Dashboard data. Server authorization always uses its current saved configuration.
Neither an App-provided label nor a discovery access snapshot grants access.

```swift
let schemes = try await client.getSchemes() // App JWT, no provider key
let selected = LLMSchemeSelection(schemeID: "excalidraw-canvas", profileID: "extra-high")
let stream = try await client.streamScheme(
    selected, billing: .platform,
    messages: [.init(role: .user, content: "Draw a flowchart")]
)

// Same contract for a parameterized image scheme. IDs/inputs are from your App's configuration.
let image = try await client.invokeScheme(
    .init(schemeID: "birthday_doodle"), billing: .platform,
    parameters: ["title": "Happy birthday", "date": "2026-11-08", "text": "For you",
                 "referenceImageURL": "https://example.com/reference.png"]
)

// Optimized BYOK keeps the Scheme prompt, but never selects a platform model option.
let ownModelStream = try await client.streamScheme(
    .init(schemeID: "excalidraw-canvas"), billing: .byok(model: .other("user/model-id")),
    messages: [.init(role: .user, content: "Draw a flowchart")]
)

// Existing AgentExecutor/local drawing tools can use the selected Scheme without a new loop.
let provider = LLMSchemeProvider(client: client, selection: selected, billing: .platform)
let executor = AgentExecutor(llmProvider: provider, toolRegistry: toolRegistry)
```

The adapter's legacy `LLMProvider.model` argument cannot override the selected Scheme option;
use descriptor capabilities/model metadata only for local UI/context-budget hints. Keep agentID
nil or equal to schemeID. `LLMState`'s existing model-only conversation API remains unchanged;
Apps opt into the Scheme APIs/adapter explicitly rather than silently changing saved conversations.

For the existing state-layer loop, wrap **creation** in `client.withScheme(selection, billing:)`.
It persists a non-secret `Conversation.schemeConnection`; subsequent send/regenerate/resume/compact
calls automatically resolve that route. Default platform profiles are resolved and pinned before
uploads. A conflicting explicit scope fails instead of changing a saved conversation's route.
To intentionally change a platform Profile or BYOK model while idle, call
`state.updateSchemeConnection(_:in:)` before the next send. Scheme, billing source and connection
identity must stay unchanged; switching those requires a new conversation. Persisted stores opt into
`LLMSchemeConversationPersistenceProvider` to atomically update that field. Unsupported/failed writes
keep the old selection, and sending is blocked while a routing update is being saved.

For persisted BYOK Scheme conversations, pass `connectionID:` to `withScheme` and inject
`schemeCredentialsProvider: (connectionID, model) async throws -> LLMBYOKCredentials` when creating
`LLMState` or `LLMStateObject`. Resolve the saved connection by ID, never the UI's current selection.
Keys remain memory-only. Each generation reauthenticates and snapshots credentials once, shared by
tool rounds, overflow retries, titles and summaries; missing credentials fail without platform fallback.
Auxiliary calls keep their own prompts and do not execute the drawing Scheme's tools.

Scheme preflight checks the actual billing/resource/profile through `/access/evaluate` before uploads
or retry history deletion, even without a host accessPolicy callback. Invocation still rechecks on the
server. Custom persistence must round-trip `schemeConnection` (old records decode it as nil).
No `PersistenceProvider` or Core protocol change is needed. See the
[state-layer integration guide](Docs/ExcalidrawZ-Integration.md#接入现有工具和会话状态) for App setup.

Billing is required explicitly: `.platform` does not read provider keys; `.byok(model:)` requires
credentials and a selection without profileID. A nil/missing credential source throws, never bills
the platform. Image-scheme BYOK currently returns unsupported. Direct clients reject all server
Scheme APIs; their local prompts/tools remain separate. No mode falls back automatically.
Both platform and BYOK Scheme streams require `[DONE]`; interruption/corrupt frames throw before
AgentExecutor can execute partial tool arguments. Legacy platform `/chat/stream` is unchanged.

Existing clients can keep `/chat` and image aliases while migrating gradually. A model-only old
caller cannot select between two options backed by the same model; move it to Scheme/profile IDs
before introducing such duplicates. Publish the additive LLMCore DTOs, update pinned dependencies,
then deploy the Server before shipping Scheme callers. No old ChatRequest fields were changed.

## Advanced Configuration (Multi-Window)

When your application contains multiple windows or scenes, you typically need to share a single `LLMState` instance across all windows. This is particularly common in macOS applications where users can open multiple windows simultaneously.

### Implementation

To share state across multiple windows, you need to:

1. **Declare a shared `LLMState` at the App level** using `@State`
2. **Pass the same state instance** to each window's `.llmProvider()` modifier

```swift
import SwiftUI
import LLMKit

@main
struct MyApp: App {
    // Declare shared state at App level
    @State private var llmState = LLMState()

    init() {
        self._llmState = State(initialValue: LLMState(
            llmClient: .shared,
            persistenceProvider: LLMPersistenceProvider()
        ))
    }

    var body: some Scene {
        WindowGroup("Main Window", id: "main") {
            MainView()
                .llmProvider(state: llmState, client: .shared)
                .task {
                    // Refresh conversations somewhere.
                    await llmState.refreshConversations()
                }
        }

        WindowGroup("Secondary Window", id: "secondary") {
            SecondaryView()
                .llmProvider(state: llmState, client: .shared)
        }
    }
}
```
