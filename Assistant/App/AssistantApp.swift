import SwiftUI

@main
struct AssistantApp: App {
    @State private var chat = ChatModel()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(chat)
                .task { await chat.loadModel() }
        }
    }
}
