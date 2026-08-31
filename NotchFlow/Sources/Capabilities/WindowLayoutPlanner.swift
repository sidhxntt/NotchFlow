import Foundation

public enum WindowLayout: Equatable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case center, maximize
}

public enum WindowLayoutPlanner {
    public static func frame(for layout: WindowLayout, in screen: CGRect, margin: CGFloat = 0) -> CGRect {
        let halfW = screen.width / 2
        let halfH = screen.height / 2
        let target: CGRect
        switch layout {
        case .leftHalf: target = CGRect(x: screen.minX, y: screen.minY, width: halfW, height: screen.height)
        case .rightHalf: target = CGRect(x: screen.midX, y: screen.minY, width: halfW, height: screen.height)
        case .topHalf: target = CGRect(x: screen.minX, y: screen.midY, width: screen.width, height: halfH)
        case .bottomHalf: target = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: halfH)
        case .topLeft: target = CGRect(x: screen.minX, y: screen.midY, width: halfW, height: halfH)
        case .topRight: target = CGRect(x: screen.midX, y: screen.midY, width: halfW, height: halfH)
        case .bottomLeft: target = CGRect(x: screen.minX, y: screen.minY, width: halfW, height: halfH)
        case .bottomRight: target = CGRect(x: screen.midX, y: screen.minY, width: halfW, height: halfH)
        case .center: target = CGRect(x: screen.minX + screen.width / 4, y: screen.minY + screen.height / 4, width: halfW, height: halfH)
        case .maximize: target = screen
        }
        let inset = min(max(0, margin), min(target.width, target.height) / 2)
        return target.insetBy(dx: inset, dy: inset)
    }
}

public struct WindowLayoutHistory: Sendable {
    private var values: [WindowLayout] = []
    private let capacity: Int
    public init(capacity: Int = 10) { self.capacity = max(0, capacity) }
    public mutating func record(_ layout: WindowLayout) {
        values.append(layout)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
    public mutating func popRestore() -> WindowLayout? { values.popLast() }
}
