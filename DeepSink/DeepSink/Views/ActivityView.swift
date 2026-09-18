//
//  ActivityView.swift
//  DeepSink
//

import SwiftUI
import UIKit

// Thin UIActivityViewController wrapper so SessionDetailView's Export
// button can use the standard share sheet (FR-6).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
