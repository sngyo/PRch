import Foundation
import CoreTransferable
import Testing
@testable import PRch

@Test func repositoryDragProviderCanBeReadByDropDestination() async throws {
    let repositoryID = "example-org/sample-web"
    let provider = RepositoryDragItem(repositoryID: repositoryID).itemProvider
    let received: RepositoryDragItem = try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadTransferable(type: RepositoryDragItem.self) { continuation.resume(with: $0) }
    }
    #expect(received.repositoryID == repositoryID)
    #expect(!provider.hasItemConformingToTypeIdentifier("public.text"))
}
