//
//  AmeLiquidGlassView.m
//  Amethyst
//
//  Task252：Telegram LegacyGlassView 配方移植（设计说明见 .h 头注释）。
//  移植源：TelegramMessenger/Telegram-iOS @ f1dd7a2d
//    - submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/
//      LegacyGlassView.swift（CABackdropLayer + CAFilter 组装）
//    - submodules/TelegramUI/Components/MeshTransform/Sources/
//      GenerateMesh.swift（SDF 折射网格，非 wireframe 路径逐式移植）
//    - submodules/TelegramUI/Components/MeshTransform/MeshTransformApi/
//      PublicHeaders/MeshTransformApi/MeshTransformApi.h（顶点/面结构布局）
//  私有符号一律字符串拼接 + 运行时解析（TG 同款防扫描写法），
//  任一环节缺失 → +ame252_isSupported = NO → 调用方旧管线零回归。
//

#import "AmeLiquidGlassView.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - 私有类型（布局与 TG MeshTransformApi.h 逐字段一致）

typedef struct AME252Point3D {
    CGFloat x;
    CGFloat y;
    CGFloat z;
} AME252Point3D;

typedef struct AME252MeshVertex {
    CGPoint from;          // 采样位置（归一化 UV）
    AME252Point3D to;      // 显示位置（归一化 UV + 深度）
} AME252MeshVertex;

typedef struct AME252MeshFace {
    unsigned int indices[4];
    float w[4];
} AME252MeshFace;

#pragma mark - 运行时解析工具

/// CAFilter filterWithName:（类方法 imp 直调；TG 同款 GraphicsFilterProtocol 绕声明）。
static NSObject * _Nullable AME252CAFilterNamed(NSString *name) {
    Class cls = NSClassFromString(@"CAFilter");
    if (cls == nil) return nil;
    SEL sel = NSSelectorFromString(@"filterWithName:");
    Method m = class_getClassMethod(cls, sel);
    if (m == nil) return nil;
    typedef NSObject * (*AME252FilterFn)(id, SEL, NSString *);
    AME252FilterFn fn = (AME252FilterFn)method_getImplementation(m);
    if (fn == NULL) return nil;
    return fn((id)cls, sel, name);
}

/// CABackdropLayer 私有 setScale:（TG LegacyGlassView 同款，1.0 = 背景按 1x 采样）。
static void AME252BackdropSetScale(CALayer *layer, double scale) {
    if (layer == nil) return;
    SEL sel = NSSelectorFromString(@"setScale:");
    Method m = class_getInstanceMethod([layer class], sel);
    if (m == nil) return;
    typedef void (*AME252ScaleFn)(id, SEL, double);
    AME252ScaleFn fn = (AME252ScaleFn)method_getImplementation(m);
    if (fn == NULL) return;
    fn(layer, sel, scale);
}

/// "CA"+"BackdropLayer" 运行时取类（TG 字符串拼接同款）。
static Class AME252BackdropLayerClass(void) {
    NSString *name = [@"CA" stringByAppendingString:@"BackdropLayer"];
    return NSClassFromString(name);
}

/// "CAMutable"+"MeshTransform" 运行时取类（TG MeshTransform.swift 同款拼接）。
static Class AME252MutableMeshClass(void) {
    NSString *name = [@"CAMutable" stringByAppendingString:@"MeshTransform"];
    return NSClassFromString(name);
}

#pragma mark - 折射网格：GenerateMesh.swift 数学移植

/// 位移缓动贝塞尔（TG LegacyGlassView.update 传入的原始控制点）。
typedef struct AME252Bezier {
    double x1, y1, x2, y2;
} AME252Bezier;

static const AME252Bezier kAME252GlassBezier = {
    0.816137566137566, 0.20502645502645533,
    0.5806878306878306, 0.873015873015873
};

static double AME252BezierCalc(double t, double a1, double a2) {
    double a = 1.0 - 3.0 * a2 + 3.0 * a1;
    double b = 3.0 * a2 - 6.0 * a1;
    double c = 3.0 * a1;
    return ((a * t + b) * t + c) * t;
}

static double AME252BezierSlope(double t, double a1, double a2) {
    double a = 1.0 - 3.0 * a2 + 3.0 * a1;
    double b = 3.0 * a2 - 6.0 * a1;
    double c = 3.0 * a1;
    return 3.0 * a * t * t + 2.0 * b * t + c;
}

static double AME252BezierTForX(double x, double x1, double x2) {
    double t = x;
    for (int i = 0; i < 4; i++) {
        double slope = AME252BezierSlope(t, x1, x2);
        if (slope == 0.0) return t;
        t -= (AME252BezierCalc(t, x1, x2) - x) / slope;
    }
    return t;
}

/// 贝塞尔缓动求值（≥0.997 视作 1.0，TG 原式）。
static double AME252BezierPoint(const AME252Bezier *bz, double x) {
    double v = AME252BezierCalc(AME252BezierTForX(x, bz->x1, bz->x2), bz->y1, bz->y2);
    if (v >= 0.997) v = 1.0;
    return v;
}

/// 圆角矩形 SDF（Inigo Quilez 式；内部为负）。GenerateMesh.swift 同式。
static double AME252RoundedRectSDF(double x, double y, double w, double h, double r) {
    double px = x - w / 2.0;
    double py = y - h / 2.0;
    double bx = w / 2.0;
    double by = h / 2.0;
    double qx = fabs(px) - bx + r;
    double qy = fabs(py) - by + r;
    double outside = hypot(fmax(qx, 0.0), fmax(qy, 0.0));
    double inside = fmin(fmax(qx, qy), 0.0);
    return outside + inside - r;
}

/// SDF 外向梯度（归一化）。GenerateMesh.swift 同式。
static void AME252RoundedRectGradient(double x, double y, double w, double h, double r,
                                      double *outNx, double *outNy) {
    double px = x - w / 2.0;
    double py = y - h / 2.0;
    double bx = w / 2.0;
    double by = h / 2.0;
    double qx = fabs(px) - bx + r;
    double qy = fabs(py) - by + r;
    double nx = 0.0, ny = 0.0;
    if (qx > 0.0 && qy > 0.0) {
        double d = hypot(qx, qy);
        if (d > 0.0) { nx = qx / d; ny = qy / d; }
    } else if (qx > qy) {
        nx = 1.0; ny = 0.0;
    } else {
        nx = 0.0; ny = 1.0;
    }
    if (px < 0.0) nx = -nx;
    if (py < 0.0) ny = -ny;
    *outNx = nx;
    *outNy = ny;
}

/// 单点位移（方向×线性衰减×贝塞尔缓动）。GenerateMesh.swift computeDisplacement 同式。
/// 返回单位化位移（约 -1...1），sdfOut 可空。
static void AME252ComputeDisplacement(double x, double y, double w, double h,
                                      double cornerRadius, double edgeDistance,
                                      const AME252Bezier *bz,
                                      double *outDx, double *outDy, double *sdfOut) {
    double sdf = AME252RoundedRectSDF(x, y, w, h, cornerRadius);
    double nx = 0.0, ny = 0.0;
    AME252RoundedRectGradient(x, y, w, h, cornerRadius, &nx, &ny);
    double inwardX = -nx;
    double inwardY = -ny;
    double distFromEdge = -sdf;
    double weight = 0.0;
    if (edgeDistance > 0.0001) {
        double raw = 1.0 - distFromEdge / edgeDistance;
        weight = fmax(0.0, fmin(1.0, raw));
    }
    double dx = inwardX * weight;
    double dy = inwardY * weight;
    double mag = hypot(dx, dy);
    if (mag > 0.0) {
        double newMag = AME252BezierPoint(bz, mag);
        double scale = newMag / mag;
        dx *= scale;
        dy *= scale;
    }
    *outDx = dx;
    *outDy = dy;
    if (sdfOut != NULL) *sdfOut = sdf;
}

/// 模板顶点（尺寸无关：baseX + sizeScaleX * W 还原世界坐标）。
typedef struct AME252TemplateVertex {
    double baseX, sizeScaleX;
    double baseY, sizeScaleY;
    double dispX, dispY;
    double depth;
} AME252TemplateVertex;

typedef struct AME252TemplateFace {
    unsigned int i0, i1, i2, i3;
} AME252TemplateFace;

typedef struct AME252MeshTemplate {
    AME252TemplateVertex *vertices;
    int vertexCount;
    AME252TemplateFace *faces;
    int faceCount;
} AME252MeshTemplate;

/// 参考尺寸下计算模板位移（含 2pt 外圈 edgeBoost，TG templateDisplacement 同式）。
static void AME252TemplateDisplacement(double worldX, double worldY,
                                       double refW, double refH, double cornerRadius,
                                       double edgeDistance, double outerEdgeDistance,
                                       const AME252Bezier *bz,
                                       double *outDx, double *outDy) {
    double dx = 0.0, dy = 0.0, sdf = 0.0;
    AME252ComputeDisplacement(worldX, worldY, refW, refH, cornerRadius,
                              edgeDistance, bz, &dx, &dy, &sdf);
    double distToEdge = fmax(0.0, -sdf);
    double edgeBoost = 1.0;
    if (outerEdgeDistance > 0.0) {
        double t = fmax(0.0, fmin(1.0, (outerEdgeDistance - distToEdge) / outerEdgeDistance));
        edgeBoost = 1.0 + t * t * (3.0 - 2.0 * t) * 0.5;
    }
    *outDx = dx * edgeBoost;
    *outDy = dy * edgeBoost;
}

typedef struct AME252Coeff {
    double base, scale;
} AME252Coeff;

// 模板规模上界（r=26/cornerResolution=12 实测：网格 480 + 角扇 624 = 1104 点、937 面；
// 取 2048 双向上界，越界即安全丢弃多余项）。圆角半径越大网格越密，radius ≤ 64 时
// 角扇环数不变（radialSteps=cornerResolution 决定），规模不随尺寸增长。
typedef struct AME252Builder {
    AME252TemplateVertex vertices[2048];
    int vertexCount;
    AME252TemplateFace faces[2048];
    int faceCount;
    double refW, refH, radius, edgeDistance, outerEdgeDistance;
    const AME252Bezier *bz;
} AME252Builder;

static int AME252AddVertex(AME252Builder *b, double baseX, double scaleX,
                           double baseY, double scaleY, double depth) {
    if (b->vertexCount >= 2048) return b->vertexCount - 1;
    double worldX = baseX + scaleX * b->refW;
    double worldY = baseY + scaleY * b->refH;
    double dx = 0.0, dy = 0.0;
    AME252TemplateDisplacement(worldX, worldY, b->refW, b->refH, b->radius,
                               b->edgeDistance, b->outerEdgeDistance, b->bz, &dx, &dy);
    AME252TemplateVertex *v = &b->vertices[b->vertexCount];
    v->baseX = baseX; v->sizeScaleX = scaleX;
    v->baseY = baseY; v->sizeScaleY = scaleY;
    v->dispX = dx; v->dispY = dy;
    v->depth = depth;
    int idx = b->vertexCount;
    b->vertexCount++;
    return idx;
}

static void AME252AddQuadFace(AME252Builder *b, int i0, int i1, int i2, int i3) {
    if (b->faceCount >= 2048) return;
    AME252TemplateFace *f = &b->faces[b->faceCount];
    f->i0 = (unsigned int)i0; f->i1 = (unsigned int)i1;
    f->i2 = (unsigned int)i2; f->i3 = (unsigned int)i3;
    b->faceCount++;
}

/// 网格面片（四边形），TG buildGridTemplate 同序。
static void AME252BuildGrid(AME252Builder *b,
                            const AME252Coeff *xCoeffs, int xCount,
                            const AME252Coeff *yCoeffs, int yCount) {
    int indexGrid[16][16];
    for (int r = 0; r < yCount; r++) {
        for (int c = 0; c < xCount; c++) {
            indexGrid[r][c] = AME252AddVertex(b, xCoeffs[c].base, xCoeffs[c].scale,
                                              yCoeffs[r].base, yCoeffs[r].scale, 0.0);
        }
    }
    for (int r = 0; r + 1 < yCount; r++) {
        for (int c = 0; c + 1 < xCount; c++) {
            AME252AddQuadFace(b, indexGrid[r][c], indexGrid[r][c + 1],
                              indexGrid[r + 1][c + 1], indexGrid[r + 1][c]);
        }
    }
}

/// 角扇（极坐标环 + 中心扇收拢），TG buildCornerTemplate 同式。
static void AME252BuildCorner(AME252Builder *b,
                              double centerBaseX, double centerScaleX,
                              double centerBaseY, double centerScaleY,
                              double startAngle, double endAngle,
                              const double *ringRadials, int ringCount,
                              const double *angularFactors, int angularCount) {
    if (ringCount <= 0 || angularCount <= 0) return;
    int ringIndices[16][16];
    int ringVertexCounts[16];
    for (int ri = 0; ri < ringCount; ri++) {
        double r = b->radius * ringRadials[ri];
        for (int t = 0; t < angularCount; t++) {
            double angle = startAngle + (endAngle - startAngle) * angularFactors[t];
            double offsetX = r * cos(angle);
            double offsetY = r * sin(angle);
            ringIndices[ri][t] = AME252AddVertex(b,
                centerBaseX + offsetX, centerScaleX,
                centerBaseY + offsetY, centerScaleY, 0.0);
        }
        ringVertexCounts[ri] = angularCount;
    }
    for (int ri = 0; ri + 1 < ringCount; ri++) {
        for (int t = 0; t + 1 < ringVertexCounts[ri]; t++) {
            AME252AddQuadFace(b, ringIndices[ri][t], ringIndices[ri][t + 1],
                              ringIndices[ri + 1][t + 1], ringIndices[ri + 1][t]);
        }
    }
    // 中心锚（深度 -0.02）+ 跨步 2 的扇面收拢（TG 同式，含尾段补面）。
    int innermostCount = ringVertexCounts[ringCount - 1];
    if (innermostCount - 1 < 2) return;
    const int *innermost = ringIndices[ringCount - 1];
    int centerAnchor = AME252AddVertex(b, centerBaseX, centerScaleX,
                                       centerBaseY, centerScaleY, -0.02);
    int stride = 2;
    int i = 0;
    while (i + 2 <= innermostCount - 1) {
        AME252AddQuadFace(b, centerAnchor, innermost[i], innermost[i + 1], innermost[i + 2]);
        i += stride;
    }
    if (i < innermostCount - 1) {
        AME252AddQuadFace(b, centerAnchor, innermost[innermostCount - 2],
                          innermost[innermostCount - 1], innermost[innermostCount - 1]);
    }
}

/// 深度因子序列（TG depthFactorsWithOuterBand 同式）。
static int AME252DepthFactors(int count, double band, double maxRadius, double *outFactors) {
    if (count <= 0 || maxRadius <= 0.0) {
        outFactors[0] = 0.0; outFactors[1] = 1.0;
        return 2;
    }
    double bandNorm = fmax(0.0, fmin(1.0, band / maxRadius));
    int innerSegments = count - 1 > 0 ? count - 1 : 1;
    double innerMax = fmax(0.0, 1.0 - bandNorm);
    int n = 0;
    for (int i = 0; i <= innerSegments; i++) {
        outFactors[n++] = innerMax * (double)i / (double)innerSegments;
    }
    // appendUnique(innerMax) — 末位本就为 innerMax，去重即吞掉
    if (n > 0 && fabs(outFactors[n - 1] - 1.0) > 1e-4) {
        outFactors[n++] = 1.0;
    }
    return n;
}

/// 模板缓存（TG glassMeshTemplateCache 同语义；键 = 拓扑参数组）。
static NSMutableDictionary *AME252TemplateCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

/// 生成模板（圆角矩形拓扑：4 边条带 + 中心面片 + 4 角扇，TG 同构）。
static AME252MeshTemplate *AME252BuildTemplate(double cornerRadius,
                                               double edgeDistance,
                                               int cornerResolution,
                                               double outerEdgeDistance,
                                               const AME252Bezier *bz) {
    double clampedRadius = cornerRadius;
    double refW = fmax(4.0 * clampedRadius, 100.0);
    double refH = fmax(4.0 * clampedRadius, 100.0);

    int angularStepsBase = cornerResolution > 3 ? cornerResolution : 3;
    int angularSteps = (angularStepsBase % 2 == 0) ? angularStepsBase : angularStepsBase + 1;
    int radialSteps = cornerResolution > 2 ? cornerResolution : 2;
    int horizontalSegments = cornerResolution / 2 + 1 > 2 ? cornerResolution / 2 + 1 : 2;
    int verticalSegments = horizontalSegments;
    double R = clampedRadius;

    double depthFactors[32];
    int depthFactorCount = AME252DepthFactors(radialSteps, outerEdgeDistance, R, depthFactors);
    double outerToInner[32];
    int outerToInnerCount = 0;
    for (int i = depthFactorCount - 1; i >= 0; i--) {
        outerToInner[outerToInnerCount++] = depthFactors[i];
    }

    AME252Coeff topXCoeffs[16], sideYCoeffs[16], topYCoeffs[16], bottomYCoeffs[16];
    AME252Coeff leftXCoeffs[16], rightXCoeffs[16];
    for (int i = 0; i <= horizontalSegments; i++) {
        double t = (double)i / (double)horizontalSegments;
        topXCoeffs[i].base = R * (1.0 - 2.0 * t);
        topXCoeffs[i].scale = t;
        sideYCoeffs[i].base = R * (1.0 - 2.0 * t);
        sideYCoeffs[i].scale = t;
    }
    for (int i = 0; i < outerToInnerCount; i++) {
        double f = outerToInner[i];
        topYCoeffs[i].base = R * (1.0 - f);
        topYCoeffs[i].scale = 0.0;
        leftXCoeffs[i].base = R * (1.0 - f);
        leftXCoeffs[i].scale = 0.0;
    }
    for (int i = 0; i < depthFactorCount; i++) {
        double f = depthFactors[i];
        bottomYCoeffs[i].base = -R * (1.0 - f);
        bottomYCoeffs[i].scale = 1.0;
        rightXCoeffs[i].base = -R * (1.0 - f);
        rightXCoeffs[i].scale = 1.0;
    }

    AME252Builder builder;
    memset(&builder, 0, sizeof(builder));
    builder.refW = refW;
    builder.refH = refH;
    builder.radius = clampedRadius;
    builder.edgeDistance = edgeDistance;
    builder.outerEdgeDistance = outerEdgeDistance;
    builder.bz = bz;

    // 边条带 ×4 + 中心面片（TG 顺序：top / bottom / left / right / center）。
    AME252BuildGrid(&builder, topXCoeffs, horizontalSegments + 1, topYCoeffs, outerToInnerCount);
    AME252BuildGrid(&builder, topXCoeffs, horizontalSegments + 1, bottomYCoeffs, depthFactorCount);
    AME252BuildGrid(&builder, leftXCoeffs, outerToInnerCount, sideYCoeffs, verticalSegments + 1);
    AME252BuildGrid(&builder, rightXCoeffs, depthFactorCount, sideYCoeffs, verticalSegments + 1);
    AME252BuildGrid(&builder, topXCoeffs, horizontalSegments + 1, sideYCoeffs, verticalSegments + 1);

    // 角扇 ×4（TG 同序：左上 / 右上 / 右下 / 左下；环仅取 >0 径向）。
    double ringRadials[32];
    int ringCount = 0;
    for (int i = 0; i < outerToInnerCount; i++) {
        if (outerToInner[i] > 0.0) ringRadials[ringCount++] = outerToInner[i];
    }
    double angularFactors[16];
    for (int i = 0; i <= angularSteps; i++) {
        angularFactors[i] = (double)i / (double)angularSteps;
    }
    int angularCount = angularSteps + 1;

    AME252BuildCorner(&builder, R, 0.0, R, 0.0, M_PI, 1.5 * M_PI,
                      ringRadials, ringCount, angularFactors, angularCount);
    AME252BuildCorner(&builder, -R, 1.0, R, 0.0, 1.5 * M_PI, 2.0 * M_PI,
                      ringRadials, ringCount, angularFactors, angularCount);
    AME252BuildCorner(&builder, -R, 1.0, -R, 1.0, M_PI / 2.0, 0.0,
                      ringRadials, ringCount, angularFactors, angularCount);
    AME252BuildCorner(&builder, R, 0.0, -R, 1.0, M_PI, M_PI / 2.0,
                      ringRadials, ringCount, angularFactors, angularCount);

    AME252MeshTemplate *tpl = (AME252MeshTemplate *)malloc(sizeof(AME252MeshTemplate));
    if (tpl == nil) return nil;
    tpl->vertices = (AME252TemplateVertex *)malloc(sizeof(AME252TemplateVertex) * builder.vertexCount);
    tpl->faces = (AME252TemplateFace *)malloc(sizeof(AME252TemplateFace) * builder.faceCount);
    if (tpl->vertices == NULL || tpl->faces == NULL) {
        free(tpl->vertices);
        free(tpl->faces);
        free(tpl);
        return nil;
    }
    memcpy(tpl->vertices, builder.vertices, sizeof(AME252TemplateVertex) * builder.vertexCount);
    memcpy(tpl->faces, builder.faces, sizeof(AME252TemplateFace) * builder.faceCount);
    tpl->vertexCount = builder.vertexCount;
    tpl->faceCount = builder.faceCount;
    return tpl;
}

/// 模板实例化 → CAMutableMeshTransform（TG instantiateGlassMesh + MeshTransform.makeValue 同式）。
static NSObject * _Nullable AME252InstantiateMesh(AME252MeshTemplate *tpl,
                                                  CGSize size,
                                                  double magnitudeU, double magnitudeV) {
    Class cls = AME252MutableMeshClass();
    if (cls == nil || tpl == nil || tpl->vertexCount <= 0 || tpl->faceCount <= 0) return nil;

    double W = (double)size.width;
    double H = (double)size.height;
    if (W < 1.0 || H < 1.0) return nil;
    double insetPoints = -1.0;
    double insetUOffset = insetPoints / W;
    double insetVOffset = insetPoints / H;
    double usableUNorm = (W - insetPoints * 2.0) / W;
    double usableVNorm = (H - insetPoints * 2.0) / H;

    AME252MeshVertex *meshVertices = (AME252MeshVertex *)malloc(sizeof(AME252MeshVertex) * tpl->vertexCount);
    AME252MeshFace *meshFaces = (AME252MeshFace *)malloc(sizeof(AME252MeshFace) * tpl->faceCount);
    if (meshVertices == NULL || meshFaces == NULL) {
        free(meshVertices);
        free(meshFaces);
        return nil;
    }

    for (int i = 0; i < tpl->vertexCount; i++) {
        const AME252TemplateVertex *v = &tpl->vertices[i];
        double worldX = v->baseX + v->sizeScaleX * W;
        double worldY = v->baseY + v->sizeScaleY * H;
        double u = worldX / W;
        double vCoord = worldY / H;
        double mappedU = insetUOffset + u * usableUNorm;
        double mappedV = insetVOffset + vCoord * usableVNorm;
        double fromX = mappedU + v->dispX * magnitudeU;
        double fromY = mappedV + v->dispY * magnitudeV;
        fromX = fmax(0.0, fmin(1.0, fromX));
        fromY = fmax(0.0, fmin(1.0, fromY));
        meshVertices[i].from = CGPointMake(fromX, fromY);
        meshVertices[i].to.x = mappedU;
        meshVertices[i].to.y = mappedV;
        meshVertices[i].to.z = v->depth;
    }
    for (int i = 0; i < tpl->faceCount; i++) {
        meshFaces[i].indices[0] = tpl->faces[i].i0;
        meshFaces[i].indices[1] = tpl->faces[i].i1;
        meshFaces[i].indices[2] = tpl->faces[i].i2;
        meshFaces[i].indices[3] = tpl->faces[i].i3;
        meshFaces[i].w[0] = 0.0f;
        meshFaces[i].w[1] = 0.0f;
        meshFaces[i].w[2] = 0.0f;
        meshFaces[i].w[3] = 0.0f;
    }

    SEL sel = NSSelectorFromString(@"meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:");
    Method m = class_getClassMethod(cls, sel);
    if (m == nil) {
        free(meshVertices);
        free(meshFaces);
        return nil;
    }
    typedef NSObject * (*AME252MeshFn)(id, SEL, NSUInteger, AME252MeshVertex *,
                                       NSUInteger, AME252MeshFace *, NSString *);
    AME252MeshFn fn = (AME252MeshFn)method_getImplementation(m);
    NSObject *mesh = nil;
    if (fn != NULL) {
        mesh = fn((id)cls, sel, (NSUInteger)tpl->vertexCount, meshVertices,
                  (NSUInteger)tpl->faceCount, meshFaces, @"none");
    }
    free(meshVertices);
    free(meshFaces);
    if (mesh == nil) return nil;

    // subdivisionSteps = 0（TG makeValue 同款：禁细分）。
    SEL subSel = NSSelectorFromString(@"setSubdivisionSteps:");
    Method subM = class_getInstanceMethod([mesh class], subSel);
    if (subM != nil) {
        typedef void (*AME252SubFn)(id, SEL, NSInteger);
        AME252SubFn subFn = (AME252SubFn)method_getImplementation(subM);
        if (subFn != NULL) subFn(mesh, subSel, 0);
    }
    return mesh;
}

/// 玻璃折射网格总入口（模板缓存 + 实例化；TG generateGlassMesh 非调试路径同构）。
static NSObject * _Nullable AME252CreateGlassMesh(CGSize size, double cornerRadius) {
    if (size.width < 8.0 || size.height < 8.0) return nil;
    double clampedRadius = fmin(cornerRadius, fmin((double)size.width, (double)size.height) / 2.0);
    if (clampedRadius < 0.5) return nil;
    double edgeDistance = fmin(12.0, clampedRadius);
    int cornerResolution = 12;
    double outerEdgeDistance = 2.0;
    const AME252Bezier *bz = &kAME252GlassBezier;

    NSString *key = [NSString stringWithFormat:@"r%.3f|e%.3f|c%d|o%.3f|b%.12f,%.12f,%.12f,%.12f",
                     clampedRadius, edgeDistance, cornerResolution, outerEdgeDistance,
                     bz->x1, bz->y1, bz->x2, bz->y2];
    NSMutableDictionary *cache = AME252TemplateCache();
    AME252MeshTemplate *tpl = (AME252MeshTemplate *)[cache objectForKey:key];
    if (tpl == nil) {
        tpl = AME252BuildTemplate(clampedRadius, edgeDistance, cornerResolution,
                                  outerEdgeDistance, bz);
        if (tpl == nil) return nil;
        [cache setObject:[NSValue valueWithPointer:tpl] forKey:key];
    }

    double magnitudePoints = 20.0;
    double magnitudeU = magnitudePoints / (double)size.width;
    double magnitudeV = magnitudePoints / (double)size.height;
    return AME252InstantiateMesh(tpl, size, magnitudeU, magnitudeV);
}

#pragma mark - 隐式动画抑制（TG BackdropLayerDelegate 同语义）

@interface AME252GlassLayerDelegate : NSObject <CALayerDelegate>
@end

@implementation AME252GlassLayerDelegate
- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event {
    return (id<CAAction>)kCFNull;
}
@end

#pragma mark - 滤镜组

/// TG LegacyGlassView .normal 档：colorMatrix（玻璃矩阵，backdropAware）+ gaussianBlur(2)。
NSArray *AME252GlassFiltersInternal(void) {
    static NSArray *filters = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSObject *colorMatrix = AME252CAFilterNamed(@"colorMatrix");
        NSObject *blur = AME252CAFilterNamed(@"gaussianBlur");
        if (colorMatrix == nil || blur == nil) return;
        // TG 原矩阵（LegacyGlassView.update L158-163）。
        float matrix[20] = {
            2.6705f, -1.1087999f, -0.1117f, 0.0f, 0.049999997f,
            -0.3295f, 1.8914f, -0.111899994f, 0.0f, 0.049999997f,
            -0.3297f, -1.1084f, 2.8881f, 0.0f, 0.049999997f,
            0.0f, 0.0f, 0.0f, 1.0f, 0.0f
        };
        NSValue *matrixValue = [NSValue valueWithBytes:&matrix
                                               objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
        [colorMatrix setValue:matrixValue forKey:@"inputColorMatrix"];
        [colorMatrix setValue:@YES forKey:@"inputBackdropAware"];
        [blur setValue:@2.0 forKey:@"inputRadius"];
        filters = @[ colorMatrix, blur ];
    });
    return filters;
}

#pragma mark - AmeLiquidGlassView

@interface AmeLiquidGlassView ()
@property (nonatomic, strong, nullable) CALayer *ame252_backdropLayer;
@property (nonatomic, strong, nullable) CALayer *ame252_snapshotLayer;
@property (nonatomic, strong) UIView *ame252_fillView;
@property (nonatomic, strong) CAShapeLayer *ame252_rimLayer;
@property (nonatomic, strong) AME252GlassLayerDelegate *ame252_layerDelegate;
@property (nonatomic, strong, nullable) NSObject *ame252_mesh;
@property (nonatomic, assign) CGSize ame252_meshSize;
@property (nonatomic, assign) CGFloat ame252_meshRadius;
@end

@implementation AmeLiquidGlassView

+ (BOOL)ame252_isSupported {
    static BOOL supported = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = (AME252BackdropLayerClass() != nil &&
                     AME252MutableMeshClass() != nil &&
                     AME252GlassFiltersInternal() != nil);
    });
    return supported;
}

+ (nullable AmeLiquidGlassView *)ame252_glassViewWithCornerRadius:(CGFloat)radius isDark:(BOOL)isDark {
    if (![self ame252_isSupported]) return nil;
    AmeLiquidGlassView *view = [[AmeLiquidGlassView alloc] initWithFrame:CGRectZero];
    if (view == nil) return nil;
    view.ame252_cornerRadius = radius;
    view.ame252_dark = isDark;
    return view;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) return self;

    _ame252_dark = NO;
    _ame252_cornerRadius = 0.0;
    _ame252_layerDelegate = [[AME252GlassLayerDelegate alloc] init];

    // TG LegacyGlassView 同款容器设定：圆角曲线 circular + 自裁剪。
    self.layer.cornerRadius = 0.0;
    self.layer.cornerCurve = kCACornerCurveCircular;
    self.clipsToBounds = YES;
    self.userInteractionEnabled = NO;

    Class backdropClass = AME252BackdropLayerClass();
    if (backdropClass != nil) {
        CALayer *backdrop = [[backdropClass alloc] init];
        backdrop.delegate = _ame252_layerDelegate;
        AME252BackdropSetScale(backdrop, 1.0);
        backdrop.rasterizationScale = 1.0;
        backdrop.hidden = NO;
        _ame252_backdropLayer = backdrop;
        [self.layer addSublayer:backdrop];
    }

    CALayer *snapshotLayer = [CALayer layer];
    snapshotLayer.contentsGravity = kCAGravityResize;   // ScaleToFill 同语义
    snapshotLayer.magnificationFilter = kCAFilterLinear;
    snapshotLayer.hidden = YES;
    _ame252_snapshotLayer = snapshotLayer;
    [self.layer addSublayer:snapshotLayer];

    NSArray *filters = AME252GlassFiltersInternal();
    if (filters != nil) {
        _ame252_backdropLayer.filters = filters;
        _ame252_snapshotLayer.filters = filters;
    }

    // TG .panel 填充（浅 white@0.70 / 深 11%white@0.85，generateLegacyGlassImage
    // .panel 分支值）——玻璃激活时面板可读性由它独立承载。
    _ame252_fillView = [[UIView alloc] initWithFrame:self.bounds];
    _ame252_fillView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _ame252_fillView.userInteractionEnabled = NO;
    _ame252_fillView.backgroundColor = [UIColor colorWithDynamicProvider:
        ^UIColor * (UITraitCollection *tc) {
            return (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
                ? [UIColor colorWithWhite:0.11 alpha:0.85]
                : [UIColor colorWithWhite:1.0 alpha:0.70];
        }];
    [self addSubview:_ame252_fillView];

    _ame252_rimLayer = [CAShapeLayer layer];
    _ame252_rimLayer.fillColor = nil;
    _ame252_rimLayer.lineWidth = 0.8;   // TG generateLegacyGlassImage lineWidth
    _ame252_rimLayer.strokeColor = [UIColor whiteColor].CGColor;
    _ame252_rimLayer.delegate = nil;
    [self.layer addSublayer:_ame252_rimLayer];

    return self;
}

- (void)setAme252_cornerRadius:(CGFloat)radius {
    _ame252_cornerRadius = radius;
    CGFloat r = fmax(0.0, radius);
    self.layer.cornerRadius = r;
    self.ame252_fillView.layer.cornerRadius = r;
    self.ame252_fillView.layer.cornerCurve = kCACornerCurveCircular;
    [self ame252_rebuildRimPath];
    self.ame252_mesh = nil;   // 半径入网格缓存键，标记重建
    [self ame252_updateMeshIfNeeded];
}

- (void)setAme252_dark:(BOOL)dark {
    _ame252_dark = dark;
    [self ame252_rebuildRimPath];
}

- (void)ame252_rebuildRimPath {
    CGFloat r = fmax(0.0, _ame252_cornerRadius);
    CGSize size = self.bounds.size;
    if (size.width < 1.0 || size.height < 1.0) return;
    CGFloat lineWidth = 0.8;
    // TG：路径内缩 lineWidth*0.5，圆角同步内缩（CornerRadii.insetBy）。
    CGFloat inset = lineWidth * 0.5;
    CGFloat rimRadius = fmax(0.0, r - inset);
    CGRect rimRect = CGRectInset(CGRectMake(0.0, 0.0, size.width, size.height), inset, inset);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rimRect
                                                    cornerRadius:rimRadius];
    // 描边浓度：TG .panel 分支实测值——浅色白 0.60（normal）、深色白 0.15。
    CGFloat alpha = _ame252_dark ? 0.15 : 0.60;
    _ame252_rimLayer.path = path.CGPath;
    _ame252_rimLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:alpha].CGColor;
}

- (void)setAme252_backdropSnapshot:(UIImage *)snapshot {
    _ame252_backdropSnapshot = snapshot;
    BOOL snapshotMode = (snapshot != nil);
    self.ame252_snapshotLayer.hidden = !snapshotMode;
    self.ame252_backdropLayer.hidden = snapshotMode;
    if (snapshotMode) {
        self.ame252_snapshotLayer.contents = (__bridge id)snapshot.CGImage;
        self.ame252_snapshotLayer.contentsScale = snapshot.scale > 0.0 ? snapshot.scale : UIScreen.mainScreen.scale;
    } else {
        self.ame252_snapshotLayer.contents = nil;
    }
    [self ame252_applyBackdropSourceRect];
}

- (void)setAme252_backdropSourceRect:(CGRect)rect {
    _ame252_backdropSourceRect = rect;
    [self ame252_applyBackdropSourceRect];
}

- (void)ame252_applyBackdropSourceRect {
    if (self.ame252_backdropSnapshot == nil) return;
    CGRect rect = _ame252_backdropSourceRect;
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
        !isfinite(rect.size.width) || !isfinite(rect.size.height) ||
        rect.size.width < 1.0 || rect.size.height < 1.0) {
        rect = self.bounds;   // 退化：铺满自身（面板内映射）
    }
    self.ame252_snapshotLayer.frame = rect;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.ame252_fillView.frame = self.bounds;
    self.ame252_backdropLayer.frame = self.bounds;
    if (self.ame252_backdropSnapshot == nil) {
        self.ame252_snapshotLayer.frame = self.bounds;
    }
    _ame252_rimLayer.frame = self.bounds;
    [self ame252_rebuildRimPath];
    [self ame252_updateMeshIfNeeded];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection != nil &&
        (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle)) {
        // 动态色自随系统；描边浓度需手动重刷。
        [self ame252_rebuildRimPath];
    }
}

/// 折射网格按需重建（尺寸/圆角变更；TG 每次 update 重生成同语义，模板缓存兜住成本）。
- (void)ame252_updateMeshIfNeeded {
    CGSize size = self.bounds.size;
    if (size.width < 8.0 || size.height < 8.0) return;
    if (self.ame252_mesh != nil &&
        CGSizeEqualToSize(self.ame252_meshSize, size) &&
        self.ame252_meshRadius == _ame252_cornerRadius) {
        return;
    }
    NSObject *mesh = AME252CreateGlassMesh(size, _ame252_cornerRadius);
    if (mesh == nil) return;
    @try {
        [self.ame252_backdropLayer setValue:mesh forKey:@"meshTransform"];
    } @catch (NSException *e) {
        NSLog(@"[Task252] meshTransform set on backdrop failed: %@", e.name);
    }
    @try {
        [self.ame252_snapshotLayer setValue:mesh forKey:@"meshTransform"];
    } @catch (NSException *e) {
        // 快照层不支持网格时静默降级：滤镜栈照常生效（无边缘折射）。
        NSLog(@"[Task252] meshTransform set on snapshot layer skipped: %@", e.name);
    }
    self.ame252_mesh = mesh;
    self.ame252_meshSize = size;
    self.ame252_meshRadius = _ame252_cornerRadius;
}

+ (nullable NSArray *)ame252_glassFilters {
    return AME252GlassFiltersInternal();
}

@end
