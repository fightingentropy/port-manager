import Foundation

@objc public protocol PrivilegedHelperProtocol {
    func runPrivilegedCommand(_ command: String, withReply reply: @escaping (Int32, String) -> Void)
}
