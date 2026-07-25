import Testing
import Foundation
@testable import ItermplexShared

@MainActor
@Suite struct RemoteWorkspaceStoreTests {
    private func store() -> RemoteWorkspaceStore {
        RemoteWorkspaceStore(
            connection: RemoteConnection(id: UUID(), name: "B", host: "127.0.0.1", port: 1, token: "t")
        )
    }

    // MARK: - Applying snapshots

    @Test func applyingASnapshotUpdatesWorkspacesAndState() {
        let s = store()
        let id = UUID().uuidString
        s.apply(snapshotText: "{\"type\":\"snapshot\",\"workspaces\":[{\"id\":\"\(id)\",\"name\":\"demo\",\"terminals\":[]}]}")
        #expect(s.state == .connected)
        #expect(s.workspaces.first?.name == "demo")
    }

    @Test func applyingAnEmptySnapshotStillMarksTheConnectionConnected() {
        let s = store()
        s.apply(snapshotText: "{\"type\":\"snapshot\",\"workspaces\":[]}")
        #expect(s.state == .connected)
        #expect(s.workspaces.isEmpty)
    }

    @Test func applyingGarbageChangesNothing() {
        let s = store()
        s.apply(snapshotText: "not json")
        #expect(s.workspaces.isEmpty)
        #expect(s.state == .connecting)
    }

    @Test func aLaterGarbageMessageDoesNotWipeAGoodSnapshot() {
        let s = store()
        let id = UUID().uuidString
        s.apply(snapshotText: "{\"workspaces\":[{\"id\":\"\(id)\",\"name\":\"demo\"}]}")
        s.apply(snapshotText: "not json")
        #expect(s.workspaces.count == 1)
        #expect(s.state == .connected)
    }

    // MARK: - Unbuildable URLs
    //
    // `connect()` runs synchronously inside `start()`, so these are testable with no
    // socket and no network: a host containing a space, and a negative port, both make
    // `URL(string:)` return nil on this toolchain (verified directly, not assumed).

    @Test func aHostThatCannotBuildAURLGoesStraightToUnreachable() {
        let s = RemoteWorkspaceStore(
            connection: RemoteConnection(id: UUID(), name: "B", host: "not a host", port: 1, token: "t")
        )
        s.start()
        #expect(s.state == .unreachable)
    }

    @Test func aPortThatCannotBuildAURLGoesStraightToUnreachable() {
        let s = RemoteWorkspaceStore(
            connection: RemoteConnection(id: UUID(), name: "B", host: "127.0.0.1", port: -1, token: "t")
        )
        s.start()
        #expect(s.state == .unreachable)
    }

    // MARK: - Auth classification
    //
    // The status here is that of `GET /api/workspaces`, not of the WebSocket upgrade.
    // Hummingbird answers a refused upgrade with 405, so the socket's status can never
    // identify a bad token; the REST route's 401 can.

    @Test func a401ProbeStatusIsUnauthorized() {
        #expect(RemoteWorkspaceStore.connectionState(forProbeStatus: 401) == .unauthorized)
    }

    @Test func everyOtherProbeStatusIsUnreachable() {
        #expect(RemoteWorkspaceStore.connectionState(forProbeStatus: nil) == .unreachable)
        #expect(RemoteWorkspaceStore.connectionState(forProbeStatus: 200) == .unreachable)
        #expect(RemoteWorkspaceStore.connectionState(forProbeStatus: 405) == .unreachable)
        #expect(RemoteWorkspaceStore.connectionState(forProbeStatus: 500) == .unreachable)
    }

    // MARK: - Action errors

    @Test func successStatusesYieldNoActionError() {
        #expect(RemoteWorkspaceStore.actionErrorMessage(status: 200, hadTransportError: false) == nil)
        #expect(RemoteWorkspaceStore.actionErrorMessage(status: 201, hadTransportError: false) == nil)
        #expect(RemoteWorkspaceStore.actionErrorMessage(status: 204, hadTransportError: false) == nil)
    }

    @Test func a404StatusYieldsAnActionErrorMentioningTheStatus() {
        #expect(RemoteWorkspaceStore.actionErrorMessage(status: 404, hadTransportError: false)?
            .contains("404") == true)
    }

    @Test func aTransportErrorYieldsAnActionError() {
        #expect(RemoteWorkspaceStore.actionErrorMessage(status: nil, hadTransportError: true) != nil)
    }

    @Test func aTransportErrorWinsOverASuccessStatus() {
        #expect(RemoteWorkspaceStore.actionErrorMessage(status: 200, hadTransportError: true) != nil)
    }
}
