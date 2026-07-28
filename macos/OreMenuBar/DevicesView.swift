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
                .font(.callout)
                .foregroundColor(.gray)
            Text("Open the Ore app on your iPhone\nand enter the pairing code")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Device List

    private var deviceListView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected Devices")
                .font(.caption)
                .foregroundColor(.gray)
                .padding(.horizontal, 16)

            ForEach(viewModel.connectedDevices) { device in
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.callout)
                            .foregroundColor(.white)
                        Text(device.connectedAt, style: .time)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.15))
                .cornerRadius(8)
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Disconnect All

    private var disconnectAllButton: some View {
        Button(action: viewModel.disconnectAll) {
            HStack {
                Image(systemName: "power")
                Text("Disconnect All")
            }
            .font(.callout)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.red.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}
