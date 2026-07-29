//
//  SMCData.swift
//  SMC 数据类型（FourCC）与数值之间的编解码。
//
//  Apple 芯片：浮点为 4 字节 IEEE754 小端（flt）。
//  Intel/旧机型：风扇用 2 字节定点 fpe2（大端，/4）；温度常用 sp78（有符号 8.8 定点）。
//  其余整数类型 SMC 约定为大端。
//

import Foundation

public enum SMCDataDecoder {

    /// 把原始字节按类型解码为 Double。无法识别时返回 nil。
    public static func decode(type rawType: String, bytes: [UInt8]) -> Double? {
        let type = rawType.trimmingCharacters(in: .whitespaces)
        switch type {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            // 小端
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                     | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "ioft":
            // 64 位 48.16 定点
            guard bytes.count >= 8 else { return nil }
            var raw: UInt64 = 0
            for i in 0..<8 { raw |= UInt64(bytes[i]) << (8 * UInt64(i)) } // 小端
            return Double(raw) / 65536.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let v = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])   // 大端
            return Double(v) / 4.0
        case "fp2e":
            guard bytes.count >= 2 else { return nil }
            let v = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(v) / 16384.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1])) // 大端
            return Double(raw) / 256.0
        case "ui8", "si8":
            guard bytes.count >= 1 else { return nil }
            return type == "si8" ? Double(Int8(bitPattern: bytes[0])) : Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1])))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v = (v << 8) | UInt32(bytes[i]) }   // 大端
            return Double(v)
        default:
            // 兜底：单字节当 ui8
            if bytes.count == 1 { return Double(bytes[0]) }
            return nil
        }
    }

    /// 把数值按类型编码为原始字节（用于写入，例如目标转速）。
    public static func encode(type rawType: String, value: Double, size: Int) -> [UInt8] {
        let type = rawType.trimmingCharacters(in: .whitespaces)
        switch type {
        case "flt":
            let bits = Float(value).bitPattern
            // 小端
            return [UInt8(bits & 0xff),
                    UInt8((bits >> 8) & 0xff),
                    UInt8((bits >> 16) & 0xff),
                    UInt8((bits >> 24) & 0xff)]
        case "fpe2":
            let raw = UInt16(max(0, min(Double(UInt16.max), (value * 4.0).rounded())))
            return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]   // 大端
        case "ui8", "si8":
            return [UInt8(max(0, min(255, value.rounded())))]
        case "ui16":
            let raw = UInt16(max(0, min(Double(UInt16.max), value.rounded())))
            return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        default:
            // 默认按浮点小端处理（Apple 芯片风扇键多为 flt）
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xff),
                    UInt8((bits >> 8) & 0xff),
                    UInt8((bits >> 16) & 0xff),
                    UInt8((bits >> 24) & 0xff)]
        }
    }
}
