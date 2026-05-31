import SwiftUI
import BillableCore

/// A draggable, resizable block representing a single `TimeEntry`.
/// Hit-tests three zones — top edge resizes the start, bottom edge resizes the end,
/// the middle drags the whole block in time.
struct TimeBlockView: View {
    enum DragMode { case translate, resizeTop, resizeBottom }

    let height: CGFloat
    let title: String
    let subtitle: String
    let color: Color
    let isSelected: Bool
    /// When true, the block represents a currently-running entry — its bottom
    /// edge tracks the clock. Renders with a dashed lower border + a soft
    /// opacity pulse so it reads as "live" at a glance.
    var isRunning: Bool = false

    /// Called continuously during a drag with the proposed mode + delta in points.
    /// The host computes new times via TimelineGeometry and renders the preview.
    var onDrag: (DragMode, CGFloat) -> Void = { _, _ in }
    /// Called when the gesture ends; host commits the snapped value.
    var onDragEnd: (DragMode) -> Void = { _ in }
    var onTap: () -> Void = { }
    var onLongPress: () -> Void = { }

    @State private var activeMode: DragMode?
    @State private var pulseOn: Bool = false

    private static let handleHeight: CGFloat = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(isSelected ? 0.35 : 0.22))
                .opacity(isRunning ? (pulseOn ? 1.0 : 0.78) : 1.0)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(color, lineWidth: isSelected ? 2 : 1)

            if isRunning {
                // Dashed bottom edge signals the block's lower bound is "open" and tracking the clock.
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .mask(
                        Rectangle()
                            .frame(height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                    if isRunning {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.green)
                            .accessibilityLabel("Running")
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .allowsHitTesting(false)
        }
        .frame(height: max(20, height))
        .contentShape(Rectangle())
        .gesture(combinedDrag)
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4, perform: onLongPress)
        .onAppear {
            guard isRunning else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulseOn = true
            }
        }
        .onChange(of: isRunning) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulseOn = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { pulseOn = false }
            }
        }
    }

    private var combinedDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // Running blocks track the live clock; dragging them would animate
                // then snap back (commitActiveDrag early-returns for running entries).
                // Suppress drag entirely — tap/long-press still open the editor.
                guard !isRunning else { return }
                if activeMode == nil {
                    activeMode = hitTest(startY: value.startLocation.y)
                }
                guard let mode = activeMode else { return }
                onDrag(mode, value.translation.height)
            }
            .onEnded { _ in
                guard !isRunning else { return }
                if let mode = activeMode {
                    onDragEnd(mode)
                }
                activeMode = nil
            }
    }

    private func hitTest(startY: CGFloat) -> DragMode {
        if startY < Self.handleHeight { return .resizeTop }
        if startY > max(0, height - Self.handleHeight) { return .resizeBottom }
        return .translate
    }
}
