import Foundation

/// A color in extended sRGB: components can fall outside 0...1 for colors
/// beyond sRGB, such as one sampled from a Display P3 screen, so the P3,
/// OKLCH, and LCH formats keep them while HEX and RGB clamp.
struct RGBColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = min(max(alpha, 0), 1)
    }

    /// `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA`, with or without the `#`.
    init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.first == "#" { digits = digits.dropFirst() }
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count <= 4 { digits = Substring(digits.flatMap { [$0, $0] }) }
        guard let value = UInt64(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        func channel(_ shift: UInt64) -> Double { Double(rgba >> shift & 0xFF) / 255 }
        self.init(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }

    /// 0...255 per channel, clamped to sRGB.
    var bytes: (red: Int, green: Int, blue: Int, alpha: Int) {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return (byte(red), byte(green), byte(blue), byte(alpha))
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when translucent; also the color's identity
    /// in the saved colors.
    var hex: String {
        let bytes = bytes
        let rgb = String(format: "#%02X%02X%02X", bytes.red, bytes.green, bytes.blue)
        return bytes.alpha == 255 ? rgb : rgb + String(format: "%02X", bytes.alpha)
    }

    var isOpaque: Bool { bytes.alpha == 255 }

    /// Every channel rounds to a byte without clamping, so HEX loses nothing.
    var isInSRGB: Bool {
        [red, green, blue].allSatisfy { (-0.5 / 255)...(1 + 0.5 / 255) ~= $0 }
    }

    /// Hue in degrees, saturation and lightness 0...1, from the clamped color.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let r = min(max(red, 0), 1), g = min(max(green, 0), 1), b = min(max(blue, 0), 1)
        let high = max(r, g, b), low = min(r, g, b)
        let lightness = (high + low) / 2
        let delta = high - low
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        let hue: Double = switch high {
        case r: 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: 60 * ((b - r) / delta + 2)
        default: 60 * ((r - g) / delta + 4)
        }
        return (hue < 0 ? hue + 360 : hue, saturation, lightness)
    }

    init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let hue = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let saturation = min(max(saturation, 0), 1), lightness = min(max(lightness, 0), 1)
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - chroma / 2
        let (r, g, b): (Double, Double, Double) = switch hue {
        case ..<60: (chroma, x, 0)
        case ..<120: (x, chroma, 0)
        case ..<180: (0, chroma, x)
        case ..<240: (0, x, chroma)
        case ..<300: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    // MARK: - OKLCH

    var oklab: (l: Double, a: Double, b: Double) {
        let (r, g, b) = linear
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    var oklch: (lightness: Double, chroma: Double, hue: Double) {
        let lab = oklab
        return (lab.l, Self.chroma(lab.a, lab.b), Self.hue(lab.a, lab.b))
    }

    init(oklchLightness lightness: Double, chroma: Double, hue: Double, alpha: Double = 1) {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians), b = chroma * sin(radians)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        self.init(linear: (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        ), alpha: alpha)
    }

    // MARK: - CIE LCH (D50, as CSS `lch()`)

    var lch: (lightness: Double, chroma: Double, hue: Double) {
        let (x, y, z) = Self.multiply(Self.d65ToD50, Self.multiply(Self.linearSRGBToXYZ, linear))
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x / 0.3457 * 0.3585), fy = f(y), fz = f(z / (1 - 0.3457 - 0.3585) * 0.3585)
        let a = 500 * (fx - fy), b = 200 * (fy - fz)
        return (116 * fy - 16, Self.chroma(a, b), Self.hue(a, b))
    }

    init(lchLightness lightness: Double, chroma: Double, hue: Double, alpha: Double = 1) {
        let radians = hue * .pi / 180
        let fy = (lightness + 16) / 116
        let fx = fy + chroma * cos(radians) / 500, fz = fy - chroma * sin(radians) / 200
        func inverse(_ f: Double) -> Double { f * f * f > 216.0 / 24389 ? f * f * f : (116 * f - 16) * 27 / 24389 }
        let d50 = (inverse(fx) * 0.3457 / 0.3585, inverse(fy), inverse(fz) * (1 - 0.3457 - 0.3585) / 0.3585)
        self.init(linear: Self.multiply(Self.xyzToLinearSRGB, Self.multiply(Self.d50ToD65, d50)), alpha: alpha)
    }

    // MARK: - Display P3

    var displayP3: (red: Double, green: Double, blue: Double) {
        let p3 = Self.multiply(Self.xyzToLinearP3, Self.multiply(Self.linearSRGBToXYZ, linear))
        return (Self.encode(p3.0), Self.encode(p3.1), Self.encode(p3.2))
    }

    init(displayP3Red red: Double, green: Double, blue: Double, alpha: Double = 1) {
        let p3 = (Self.decode(red), Self.decode(green), Self.decode(blue))
        self.init(linear: Self.multiply(Self.xyzToLinearSRGB, Self.multiply(Self.linearP3ToXYZ, p3)), alpha: alpha)
    }

    // MARK: - Transfer and matrices (CSS Color 4)

    private typealias Vector = (Double, Double, Double)

    private var linear: Vector { (Self.decode(red), Self.decode(green), Self.decode(blue)) }

    private init(linear: Vector, alpha: Double) {
        self.init(red: Self.encode(linear.0), green: Self.encode(linear.1), blue: Self.encode(linear.2), alpha: alpha)
    }

    /// The sRGB (and Display P3) curve, mirrored for negative components.
    private static func decode(_ value: Double) -> Double {
        let magnitude = abs(value)
        let linear = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
        return value < 0 ? -linear : linear
    }

    private static func encode(_ value: Double) -> Double {
        let magnitude = abs(value)
        let encoded = magnitude <= 0.0031308 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return value < 0 ? -encoded : encoded
    }

    private static func chroma(_ a: Double, _ b: Double) -> Double { (a * a + b * b).squareRoot() }

    /// Degrees 0..<360; 0 for a gray, whose hue is meaningless.
    private static func hue(_ a: Double, _ b: Double) -> Double {
        guard chroma(a, b) > 1e-4 else { return 0 }
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    private static func multiply(_ m: [[Double]], _ v: Vector) -> Vector {
        (
            m[0][0] * v.0 + m[0][1] * v.1 + m[0][2] * v.2,
            m[1][0] * v.0 + m[1][1] * v.1 + m[1][2] * v.2,
            m[2][0] * v.0 + m[2][1] * v.1 + m[2][2] * v.2
        )
    }

    private static let d65ToD50: [[Double]] = [
        [1.0479298208405488, 0.022946793341019088, -0.05019222954313557],
        [0.029627815688159344, 0.990434484573249, -0.01707382502938514],
        [-0.009243058152591178, 0.015055144896577895, 0.7518742899580008],
    ]

    private static let d50ToD65: [[Double]] = [
        [0.955473421488075, -0.02309845494876471, 0.06325924320057072],
        [-0.0283697093338637, 1.0099953980813041, 0.021041441191917323],
        [0.012314014864481998, -0.020507649298898964, 1.330365926242124],
    ]

    private static let linearSRGBToXYZ: [[Double]] = [
        [0.41239079926595934, 0.357584339383878, 0.1804807884018343],
        [0.21263900587151027, 0.715168678767756, 0.07219231536073371],
        [0.01933081871559182, 0.11919477979462598, 0.9505321522496607],
    ]

    private static let xyzToLinearSRGB: [[Double]] = [
        [3.2409699419045226, -1.537383177570094, -0.4986107602930034],
        [-0.9692436362808796, 1.8759675015077202, 0.04155505740717559],
        [0.05563007969699366, -0.20397695888897652, 1.0569715142428786],
    ]

    private static let linearP3ToXYZ: [[Double]] = [
        [0.4865709486482162, 0.26566769316909306, 0.1982172852343625],
        [0.2289745640697488, 0.6917385218365064, 0.079286914093745],
        [0.0, 0.04511338185890264, 1.043944368900976],
    ]

    private static let xyzToLinearP3: [[Double]] = [
        [2.493496911941425, -0.9313836179191239, -0.40271078445071684],
        [-0.8294889695615747, 1.7626640603183463, 0.023624685841943577],
        [0.03584583024378447, -0.07617238926804182, 0.9568845240076872],
    ]
}
