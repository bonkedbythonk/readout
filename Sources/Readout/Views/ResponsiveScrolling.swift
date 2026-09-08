import AppKit
import ObjectiveC.runtime

/// Puts SwiftUI's scroll views back on AppKit's responsive scrolling path.
///
/// SwiftUI backs `ScrollView` with a private `NSScrollView` subclass whose
/// `isCompatibleWithResponsiveScrolling` answers false. On that path AppKit
/// applies wheel events on the main thread on every *second* display refresh,
/// so on a 120 Hz panel the content moves at 60 Hz however idle the app is.
/// Flipping the class flag is what Finder and AppKit's own scroll views get by
/// default.
///
/// This reaches into a private class by name, so every step is optional: if
/// the class is gone or renamed in a future release, scrolling stays at the
/// old rate instead of the app failing.
@MainActor
enum ResponsiveScrolling {
    /// What `enable` managed to do, so a silent no-op can be told apart from a
    /// working patch. Reported by `READOUT_BENCH=1`.
    private(set) static var outcome = "not attempted"

    /// Must run before the first scene builds its views: AppKit reads the flag
    /// when a scroll view is created, not when it draws.
    static let enable: Void = {
        let candidates = ["SwiftUI.HostingScrollView", "_TtC7SwiftUI17HostingScrollView"]
        guard let target = candidates.lazy.compactMap({ NSClassFromString($0) }).first else {
            outcome = "no HostingScrollView class"
            return
        }
        guard target is NSScrollView.Type, let metaClass = object_getClass(target) else {
            outcome = "\(target) is not an NSScrollView"
            return
        }

        let selector = NSSelectorFromString("isCompatibleWithResponsiveScrolling")
        let answerTrue: @convention(block) (AnyObject) -> Bool = { _ in true }
        let implementation = imp_implementationWithBlock(answerTrue)

        if let method = class_getClassMethod(target, selector) {
            method_setImplementation(method, implementation)
            outcome = "replaced on \(target)"
        } else {
            class_addMethod(metaClass, selector, implementation, "B@:")
            outcome = "added to \(target)"
        }
    }()

    /// Reads back what AppKit will actually answer, rather than trusting that
    /// the patch landed.
    static func verify() -> String {
        _ = enable
        let selector = NSSelectorFromString("isCompatibleWithResponsiveScrolling")
        guard let target = NSClassFromString("SwiftUI.HostingScrollView")
            ?? NSClassFromString("_TtC7SwiftUI17HostingScrollView")
        else { return "\(outcome); class not found" }
        let responds = (target as AnyObject).responds(to: selector)
        let answer = responds
            ? ((target as AnyObject).perform(selector) != nil)
            : false
        return "\(outcome); responds=\(responds) answers=\(answer)"
    }
}
