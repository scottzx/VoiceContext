import SwiftUI

struct PurchaseUnlockView: View {
    @Bindable var trial: TrialEntitlementController

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(trial.isUnlocked ? "已永久解锁" : trial.remainingTimeText)
                        .font(.headline)
                    ProgressView(value: trial.isUnlocked ? 1 : trial.progressFraction)
                        .tint(trial.isPurchaseLocked ? .orange : .accentColor)
                    Text(trial.availabilityCaption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("这是一次性永久解锁，不是订阅。无业务服务器。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            if !trial.isUnlocked {
                Section {
                    Button {
                        Task { await trial.purchase() }
                    } label: {
                        if trial.isBusy {
                            ProgressView()
                        } else {
                            Text(purchaseButtonTitle)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trial.isBusy)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    Button("恢复购买") {
                        Task { await trial.restore() }
                    }
                    .disabled(trial.isBusy)
                } footer: {
                    Text("试用到期后仍可录音并保存音频；解锁后自动继续转写积压任务。")
                }
            }

            if let statusMessage = trial.statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("试用与永久解锁")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            trial.start()
            trial.noteAppBecameActive()
            await trial.refreshFromStore()
        }
    }

    private var purchaseButtonTitle: String {
        if let displayPrice = trial.displayPrice, !displayPrice.isEmpty {
            return "永久解锁 · \(displayPrice)"
        }
        return "永久解锁"
    }
}

struct TrialQuotaSettingsSection: View {
    @Bindable var trial: TrialEntitlementController

    var body: some View {
        Section("转写试用") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(trial.isUnlocked ? "已永久解锁" : trial.remainingTimeText)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if trial.isPurchaseLocked {
                        Text("待解锁")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else if !trial.isUnlocked, trial.progressFraction >= 0.9 {
                        Text("即将到期")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                ProgressView(value: trial.isUnlocked ? 1 : trial.progressFraction)
                Text(trial.availabilityCaption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            NavigationLink {
                PurchaseUnlockView(trial: trial)
            } label: {
                Label("试用与永久解锁", systemImage: "lock.open")
            }
        }
    }
}
