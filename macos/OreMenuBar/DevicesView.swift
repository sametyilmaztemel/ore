import SwiftUI

// MARK: - Devices Tab

public struct DevicesView: View {
    @ObservedObject var viewModel: OreViewModel

    public init(viewModel: OreViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.connectedDevices.isEmpty {
                emptyStateView
            } else {
                deviceListView
            }

            if !viewModel.connectedDevices.isEmpty {
                disconnectAllButton
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 40))
                .foregroundColor(.gray)
            Text("No devices connected")