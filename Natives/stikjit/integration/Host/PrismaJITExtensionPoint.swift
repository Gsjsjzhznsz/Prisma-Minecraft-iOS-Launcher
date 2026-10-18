import ExtensionFoundation

// ★ Task293：内置 JIT Helper 的扩展点声明（PocketJJITExtensionPoint 同构）。
//   点名 = "PrismaJITHelper"；appex 的 Info.plist 里 EXExtensionPointIdentifier
//   必须是 "<宿主 bundle id>.PrismaJITHelper"（即
//   com.prisma-devs.prisma.PrismaJITHelper），AppExtensionPoint.Monitor 按
//   (host=com.prisma-devs.prisma, name=PrismaJITHelper) 发现。

@available(iOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var prismaJITHelper: AppExtensionPoint {
        Name("PrismaJITHelper")
    }
}
