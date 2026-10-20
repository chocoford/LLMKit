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

## BYOK through LLMServer

There is one configuration-driven `LLMBYOKProvider`. OpenRouter, OpenAI, Anthropic and
Google Gemini are ready-made `LLMBYOKConfiguration` presets, not separate implementations.
Custom connections use the same API. Requests still go through LLMServer, which retains
app authentication, Domain Agent prompts, tool policy and chat/SSE. BYOK does not use the
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
Google thought signatures and OpenRouter extensions. Only Chat Completions-compatible APIs
with Bearer-key authentication are supported, not arbitrary native Responses/Messages/Gemini,
extra-header/query authentication or provider-specific image/audio/video APIs. The Anthropic
and Gemini presets use official compatibility endpoints, not OpenRouter. The OpenRouter
preset selects the existing image-response extension for known image variants; other presets
forward those model IDs through the normal chat adapter rather than reject them by name.
This does not add support for native image endpoints or guarantee a model's capabilities.

BYOK accepts model IDs not present in `SupportedModel` via `.other("model-id")`. Neither
provider-family prefixes nor the Domain Agent's `modelProfiles` / `allowedModels` are model
admission rules in BYOK mode. Only basic model-ID syntax/size validation remains. Provider
errors are returned without a replacement model or a platform-key retry. Use the user's
connection/model selection in BYOK UI, not the platform model menu or its paid tiers.

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

- The App JWT stays in `Authorization`. Key-free config uses `X-LLM-BYOK-Configuration`;
  the model key travels separately in `X-LLM-BYOK-Key`, never the JSON body.
- SDK requests use `/chat/byok`, `/chat/byok/stream` and `/chat/byok/ask`. Older servers
  reject unsupported routes/configuration rather than silently billing the platform.
  Keys are never sent to auth, credits, tools, push, search or upload endpoints.
- LLMServer processes the key only in request memory. The BYOK path does not write it to a
  database, conversation, metadata, credit transaction or application log. This is backend
  forwarding, not a mode where the key never leaves the device.
- Custom endpoints must resolve only to public IP addresses. LLMServer pins the checked
  address, verifies TLS against the original host, and disallows redirects/proxies. Custom
  Domain Agent hosts need server approval via `LLM_BYOK_TRUSTED_AGENT_HOSTS`, because they
  receive the server-held prompt; the four official preset hosts are preapproved.
- BYOK model inference does not consume platform model credits; tools/search/uploads retain
  their own rules. Product authentication, agent registration, endpoint trust and tool policy
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
inbound `X-LLM-BYOK-Key` and outbound provider `Authorization` from captured requests.

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
