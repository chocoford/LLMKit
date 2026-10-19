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

BYOK currently supports a user's own **OpenRouter API key**. Requests still go through
LLMServer, which retains app authentication, Domain Agent prompts, model/plan validation,
tool policy and the normal chat/SSE response format.

The host app owns key storage. Supply a callback that reads the key from your Keychain
implementation; LLMKit calls it for each model request and does not persist its result:

```swift
func makeBYOKClient(
    readAPIKey: @escaping @Sendable () async throws -> String
) -> LLMClient {
    LLMClient(
        authProvider: .xcode(bundleID: "com.example.app"),
        byokCredentialsProvider: {
            LLMBYOKCredentials(
                provider: .openRouter,
                apiKey: try await readAPIKey()
            )
        }
    )
}
```

The callback also covers Agent rounds, `ask`, title generation, temporary chat and
compaction. These auxiliary requests use their existing model selections and are billed
to the user's provider account as well. Existing chat and state APIs need no changes.
If the callback is omitted, behavior remains platform-billed. A dynamic callback may
return nil **only when the user explicitly selects platform billing**. If BYOK is selected
but no key is available, throw `LLMBYOKConfigurationError.invalidAPIKey` instead of
silently returning nil.

- The app login token stays in `Authorization`; the model key uses separate headers.
- The SDK automatically uses `/chat/byok`, `/chat/byok/stream`, and `/chat/byok/ask` so an
  old server fails with 404 instead of ignoring credentials and billing the platform.
  Keys are never sent to auth, credits,
  push, search or upload endpoints. BYOK requests require HTTPS (local loopback HTTP is
  allowed for development), and HTTP redirects are not followed.
- LLMServer uses the key in request memory. It does not save it in a database, conversation,
  metadata, credit transaction or application log. The server necessarily sees the key
  while forwarding the request; this is not direct-to-provider or end-to-end encryption.
- BYOK model requests do not check or deduct platform model credits. Search and upload
  retain their own authentication and billing rules. BYOK responses contain no platform
  credit settlement; non-streaming responses still include provider token usage.
- Invalid credentials, provider failures and interrupted streams return errors. They never
  switch automatically to the platform key. Provider auth/balance errors use HTTP 502
  with a BYOK-specific message, rather than triggering platform login or recharge flows.
- BYOK streaming succeeds only after a complete server `[DONE]` frame. Premature EOF or
  malformed SSE/UTF-8/JSON/response data throws, even if some text or tool arguments have
  already been received. Platform streaming keeps its existing EOF compatibility.

Deploy LLMServer with BYOK completion-marker support before enabling this SDK option. Existing Domain Agent
model allowlists and plan requirements still apply; BYOK does not bypass product access.
If your App disables its send button when platform credits are depleted, adjust that UI
condition for BYOK inference. Tool calls can still require platform credits.
The server deployment's proxies, tracing and error-reporting systems must also omit the
`X-LLM-BYOK-Key` header from captured requests.

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
