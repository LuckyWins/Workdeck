import SwiftUI

/// A simple front view of a MacBook for the landing tour (landing tour animations spec §4.3): a dark bezel with a
/// notch around `screen`, a thin base with a lip. `lidOpen` folds the lid down toward the hinge (1 open … 0 shut).
/// Neutral grays, no logo: it reads as "a MacBook", not a product render.
struct DrawnMacBook<Screen: View>: View {
    static var screenSize: CGSize { CGSize(width: 512, height: 320) }
    static var bezel: CGFloat { 10 }
    static var lidSize: CGSize { CGSize(width: screenSize.width + 2 * bezel, height: screenSize.height + 2 * bezel) }
    static var baseSize: CGSize { CGSize(width: 600, height: 14) }
    static var size: CGSize { CGSize(width: baseSize.width, height: lidSize.height + baseSize.height) }
    /// How far the lid turns to lie on the base, seen from the front: just short of edge-on.
    static var closedAngle: Double { 90 }
    /// The shut lid's edge on the base, seen from the front.
    static var lidEdge: CGFloat { 5 }
    /// The camera housing at the screen's top, in screen points.
    static var housing: CGSize { CGSize(width: 64, height: 14) }

    let lidOpen: Double
    /// 1 lit … 0 dark: the screen goes dark before the lid folds and lights up once it is open, as on a real Mac (and a
    /// dark lid folding costs a fraction of a lit one in the animation's file).
    var screenOn = 1.0
    @ViewBuilder let screen: () -> Screen

    var body: some View {
        VStack(spacing: 0) {
            if lidOpen < 1 {
                // Turning: drawn as its projection (the screen is dark meanwhile); a 3D effect would not show in the
                // offscreen capture, which draws only 2D transforms.
                let angle = Self.closedAngle * (1 - lidOpen)
                ZStack(alignment: .bottom) {
                    // Shut, the lid is edge-on: only its edge below shows, not a hairline of its outline.
                    ZStack {
                        LidProjection(angle: angle, inset: 0, topRadius: 18, bottomRadius: 4)
                            .fill(Color(white: 0.1 * (0.5 + 0.5 * lidOpen)))
                        LidProjection(angle: angle, inset: 0, topRadius: 18, bottomRadius: 4)
                            .stroke(Color(white: 0.32), lineWidth: 1.5)
                        LidProjection(angle: angle, inset: Self.bezel, topRadius: 10, bottomRadius: 0)
                            .fill(Color.black)
                    }
                    .frame(width: Self.lidSize.width, height: Self.lidSize.height)
                    .opacity(lidOpen > 0.001 ? 1 : 0)
                    // The lid's aluminum edge shows as it lies down on the base.
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(LinearGradient(colors: [Color(white: 0.7), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                        .frame(width: Self.baseSize.width - 6, height: Self.lidEdge)
                        .opacity(max(0, min(1, (angle - 70) / 18)))
                }
                .frame(width: Self.lidSize.width, height: Self.lidSize.height)
            } else {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 18)
                    .fill(Color(white: 0.1))
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 18)
                            .stroke(Color(white: 0.32), lineWidth: 1.5)
                    )
                screen()
                    .frame(width: Self.screenSize.width, height: Self.screenSize.height)
                    .overlay(Color.black.opacity(1 - screenOn))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 10))
                    .padding(.top, Self.bezel)
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 0)
                    .fill(Color.black)
                    .frame(width: Self.housing.width, height: Self.housing.height)
                    .padding(.top, Self.bezel)
            }
            .frame(width: Self.lidSize.width, height: Self.lidSize.height)
            }

            ZStack(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 10, bottomTrailingRadius: 10, topTrailingRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.78), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 5, bottomTrailingRadius: 5, topTrailingRadius: 0)
                    .fill(Color(white: 0.45))
                    .frame(width: 90, height: 5)
            }
            .frame(width: Self.baseSize.width, height: Self.baseSize.height)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
    }
}

/// The lid turned `angle` degrees on its hinge toward the viewer, seen from the front in perspective (the user,
/// 2026-11-10: a lid that only shrinks downward does not read as closing): its top edge comes forward, so it widens
/// and drops, until the lid lies on the base as a thin band. `inset` draws the screen inside the bezel.
struct LidProjection: Shape {
    var angle: Double
    var inset: CGFloat
    /// The outline's corner radii, kept in the projection.
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// The eye's distance from the hinge, in lid heights, chosen so the lid's near edge is as wide as the base when it
    /// lies down: base / lid = eye / (eye − 1).
    static var eyeDistance: CGFloat {
        let ratio = DrawnMacBook<EmptyView>.baseSize.width / DrawnMacBook<EmptyView>.lidSize.width
        return ratio / (ratio - 1)
    }
    static let cornerSteps = 8

    func path(in rect: CGRect) -> Path {
        let radians = angle * .pi / 180
        let height = rect.height, centerX = rect.midX, eye = Self.eyeDistance * height
        // A point `x` across and `up` above the hinge, projected into the rect (the hinge is its bottom edge).
        func project(_ point: CGPoint) -> CGPoint {
            let scale = eye / (eye - point.y * CGFloat(sin(radians)))
            return CGPoint(x: centerX + (point.x - centerX) * scale, y: rect.maxY - point.y * CGFloat(cos(radians)) * scale)
        }
        // The flat outline (x across, y up from the hinge), counterclockwise from the bottom left, corners sampled.
        let left = rect.minX + inset, right = rect.maxX - inset, bottom = inset, top = height - inset
        var outline: [CGPoint] = []
        func corner(_ center: CGPoint, _ radius: CGFloat, from start: Double) {
            guard radius > 0 else {
                outline.append(CGPoint(x: center.x, y: center.y))
                return
            }
            for step in 0 ... Self.cornerSteps {
                let a = (start + 90 * Double(step) / Double(Self.cornerSteps)) * .pi / 180
                outline.append(CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a))))
            }
        }
        corner(CGPoint(x: left + bottomRadius, y: bottom + bottomRadius), bottomRadius, from: 180)
        corner(CGPoint(x: right - bottomRadius, y: bottom + bottomRadius), bottomRadius, from: 270)
        corner(CGPoint(x: right - topRadius, y: top - topRadius), topRadius, from: 0)
        corner(CGPoint(x: left + topRadius, y: top - topRadius), topRadius, from: 90)
        var path = Path()
        path.addLines(outline.map(project))
        path.closeSubpath()
        return path
    }
}
