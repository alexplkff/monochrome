import CoreImage
import Foundation
import Metal

// Stateless GPU grain, tonal statistics, and compensation passes. Size is measured
// relative to the whole frame. The same pipeline serves preview and export.
enum FilmGrainFilter {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func prepare(device: MTLDevice) throws {
        _ = try FilmGrainKernel.pipeline(for: device)
    }

    static func apply(to image: CIImage, settings: GrainSettings, seed: UInt32) throws -> CIImage {
        guard settings.safeStrength > 0 else { return image }
        guard let encoded = image.matchedFromWorkingSpace(to: colorSpace) else {
            throw CameraError.photoProcessingFailed
        }
        let result = try FilmGrainKernel.apply(withExtent: image.extent, inputs: [encoded], arguments: [
            "frame": CIVector(cgRect: image.extent),
            "iso": NSNumber(value: settings.safeISO),
            "strength": NSNumber(value: settings.safeStrength / 100),
            "brand": NSNumber(value: settings.brand.index),
            "seed": NSNumber(value: seed & 0x00FF_FFFF)
        ])
        guard let matched = result.matchedToWorkingSpace(from: colorSpace) else {
            throw CameraError.photoProcessingFailed
        }
        return matched
    }
}

private final class FilmGrainKernel: CIImageProcessorKernel {
    struct Pipelines {
        let grain: MTLComputePipelineState
        let reduce: MTLComputePipelineState
        let correct: MTLComputePipelineState
    }
    private static let pipelineLock = NSLock()
    nonisolated(unsafe) private static var pipelines: [UInt64: Pipelines] = [:]

    static func pipeline(for device: MTLDevice) throws -> Pipelines {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let pipeline = pipelines[device.registryID] { return pipeline }
        let library = try device.makeLibrary(source: source, options: nil)
        func make(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw CameraError.photoProcessingFailed }
            return try device.makeComputePipelineState(function: function)
        }
        let pipeline = try Pipelines(grain: make("filmGrain"), reduce: make("grainMeans"), correct: make("correctGrain"))
        pipelines[device.registryID] = pipeline
        return pipeline
    }

    override class var outputFormat: CIFormat { .RGBAh }
    override class var synchronizeInputs: Bool { false }
    override class func formatForInput(at inputIndex: Int32) -> CIFormat { .RGBAh }
    override class func roi(forInput inputIndex: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        // Moment matching must see the same complete frame when a caller requests a crop.
        (arguments?["frame"] as? CIVector)?.cgRectValue ?? outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let source = input.metalTexture,
              let destination = output.metalTexture, let buffer = output.metalCommandBuffer,
              let frame = arguments?["frame"] as? CIVector,
              let iso = arguments?["iso"] as? NSNumber,
              let strength = arguments?["strength"] as? NSNumber,
              let brand = arguments?["brand"] as? NSNumber,
              let seed = arguments?["seed"] as? NSNumber else {
            throw CameraError.photoProcessingFailed
        }
        let pipeline = try pipeline(for: buffer.device)
        let width = pipeline.grain.threadExecutionWidth
        let height = max(1, min(8, pipeline.grain.maxTotalThreadsPerThreadgroup / width))
        let columns = (source.width + width - 1) / width
        let rows = (source.height + height - 1) / height
        let groupCount = columns * rows
        // The intermediate only needs luminance; avoid three unused 16-bit channels
        // (about 147 MB at 24 MP). Original alpha is read again in the final pass.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
                                                                  width: source.width, height: source.height,
                                                                  mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let intermediate = buffer.device.makeTexture(descriptor: descriptor),
              let statistics = buffer.device.makeBuffer(length: groupCount * 16 * MemoryLayout<SIMD2<Int32>>.stride,
                                                        options: .storageModePrivate),
              let means = buffer.device.makeBuffer(length: 16 * MemoryLayout<Float>.stride,
                                                   options: .storageModePrivate) else {
            throw CameraError.photoProcessingFailed
        }
        var uniforms = [
            SIMD4<Float>(Float(output.region.minX - input.region.minX),
                         Float(output.region.minY - input.region.minY),
                         Float(input.region.minX - frame.x), Float(input.region.minY - frame.y)),
            SIMD4<Float>(Float(min(frame.z, frame.w)), iso.floatValue, strength.floatValue, brand.floatValue),
            SIMD4<Float>(seed.floatValue, Float(columns), Float(groupCount), 0)
        ]
        guard let encoder = buffer.makeComputeCommandEncoder() else { throw CameraError.photoProcessingFailed }
        encoder.setComputePipelineState(pipeline.grain)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(intermediate, index: 1)
        encoder.setBuffer(statistics, offset: 0, index: 1)
        uniforms.withUnsafeMutableBytes { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        // Full groups are required for the threadgroup statistics barriers at the image edges.
        encoder.dispatchThreadgroups(MTLSize(width: columns, height: rows, depth: 1),
                                      threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        guard let reduction = buffer.makeComputeCommandEncoder() else { throw CameraError.photoProcessingFailed }
        reduction.setComputePipelineState(pipeline.reduce)
        reduction.setBuffer(statistics, offset: 0, index: 0)
        reduction.setBuffer(means, offset: 0, index: 1)
        var count = UInt32(groupCount)
        reduction.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
        reduction.dispatchThreadgroups(MTLSize(width: 16, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        reduction.endEncoding()
        guard let correction = buffer.makeComputeCommandEncoder() else { throw CameraError.photoProcessingFailed }
        correction.setComputePipelineState(pipeline.correct)
        correction.setTexture(source, index: 0)
        correction.setTexture(intermediate, index: 1)
        correction.setTexture(destination, index: 2)
        correction.setBuffer(means, offset: 0, index: 1)
        uniforms.withUnsafeMutableBytes { bytes in
            correction.setBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        correction.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        correction.endEncoding()
    }

    // Three illustrative families derived from the accepted v0.1 textures. A normalized
    // separable Gaussian lattice keeps strength independent from interpolation phase.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    uint hash32(uint v) {
        v ^= v >> 16; v *= 0x7feb352du;
        v ^= v >> 15; v *= 0x846ca68bu;
        return v ^ (v >> 16);
    }
    float white(int2 p, uint seed) {
        uint h = hash32(as_type<uint>(p.x) * 0x9e3779b9u ^ as_type<uint>(p.y) * 0x85ebca6bu ^ seed);
        float a = float(h & 0x00ffffffu) / 16777216.0;
        float b = float(hash32(h + 1013u) & 0x00ffffffu) / 16777216.0;
        float c = float(hash32(h + 2027u) & 0x00ffffffu) / 16777216.0;
        return (a + b + c - 1.5) * 2.0;
    }
    float gaussianCell(int2 p, float side, uint seed) {
        float value = 0.0;
        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                float weight = (x == 0 ? 1.0 : side) * (y == 0 ? 1.0 : side);
                value += white(p + int2(x, y), seed) * weight;
            }
        }
        return value / (1.0 + 2.0 * side * side);
    }
    float field(float2 p, float sigma, uint seed) {
        int2 cell = int2(floor(p));
        float2 f = fract(p);
        float side = exp(-0.5 / (sigma * sigma));
        float a = gaussianCell(cell, side, seed);
        float b = gaussianCell(cell + int2(1, 0), side, seed);
        float c = gaussianCell(cell + int2(0, 1), side, seed);
        float d = gaussianCell(cell + int2(1, 1), side, seed);
        float rho = 2.0 * side / (1.0 + 2.0 * side * side);
        float2 variance = (1.0 - f) * (1.0 - f) + f * f + 2.0 * f * (1.0 - f) * rho;
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) / sqrt(variance.x * variance.y);
    }
    kernel void filmGrain(texture2d<half, access::read> input [[texture(0)]],
                          texture2d<half, access::write> output [[texture(1)]],
                          constant float4 *u [[buffer(0)]], device int2 *statistics [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]], uint2 group [[threadgroup_position_in_grid]],
                          uint local [[thread_index_in_threadgroup]]) {
        threadgroup atomic_int sums[16];
        threadgroup atomic_int counts[16];
        if (local < 16) { atomic_store_explicit(&sums[local], 0, memory_order_relaxed);
                          atomic_store_explicit(&counts[local], 0, memory_order_relaxed); }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        bool valid = gid.x < output.get_width() && gid.y < output.get_height();
        half4 original = valid ? input.read(gid) : half4(0.0);
        float alpha = float(original.a);
        float value = alpha > 0.0 ? float(original.r) / alpha : 0.0;
        float strength = u[1].z;
        bool active = valid && strength > 0.0 && value > 0.0 && value < 1.0 && alpha > 0.0;
        float delta = 0.0;
        if (active) {
        uint seed = uint(u[2].x);
        float scale = max(0.01, u[1].x / 685.0 * pow(u[1].y / 400.0, 0.36));
        float2 p = (float2(gid) + u[0].zw + 0.5) / scale - 0.5;
        float noise;
        if (u[1].w < 0.5) {
            noise = (0.84 * field(p, 0.72, seed) + 0.32 * field(p / 2.8, 0.72, seed + 571u)) / 0.8988882;
        } else if (u[1].w < 1.5) {
            noise = field(p, 0.48, seed);
        } else {
            noise = field(p, 0.32, seed);
        }
        float envelope = pow(max(0.0, sin(value * M_PI_F)), 0.55);
        float room = min(value, 1.0 - value);
        delta = room * tanh((18.0 / 255.0) * strength * envelope * noise / room);
        uint bin = min(15u, uint(value * 16.0));
        atomic_fetch_add_explicit(&sums[bin], int(round(delta * 65536.0)), memory_order_relaxed);
        atomic_fetch_add_explicit(&counts[bin], 1, memory_order_relaxed);
        }
        if (valid) {
            half result = half((value + delta) * alpha);
            output.write(active ? half4(result, result, result, original.a) : original, gid);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (local < 16) {
            uint index = (group.y * uint(u[2].y) + group.x) * 16u + local;
            statistics[index] = int2(atomic_load_explicit(&sums[local], memory_order_relaxed),
                                     atomic_load_explicit(&counts[local], memory_order_relaxed));
        }
    }
    kernel void grainMeans(device const int2 *statistics [[buffer(0)]], device float *means [[buffer(1)]],
                           constant uint &count [[buffer(2)]], uint local [[thread_index_in_threadgroup]],
                           uint group [[threadgroup_position_in_grid]]) {
        threadgroup float2 partial[256];
        float2 sum = float2(0.0);
        for (uint i = local; i < count; i += 256u) { sum += float2(statistics[i * 16u + group]); }
        partial[local] = sum;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128; stride > 0; stride >>= 1) {
            if (local < stride) partial[local] += partial[local + stride];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (local == 0) means[group] = partial[0].x / max(1.0, partial[0].y) / 65536.0;
    }
    kernel void correctGrain(texture2d<half, access::read> input [[texture(0)]],
                             texture2d<half, access::read> grained [[texture(1)]],
                             texture2d<half, access::write> output [[texture(2)]],
                             constant float4 *u [[buffer(0)]], device const float *means [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        uint2 sourcePoint = uint2(int2(gid) + int2(u[0].xy));
        half4 original = input.read(sourcePoint);
        float alpha = float(original.a);
        float value = alpha > 0.0 ? float(original.r) / alpha : 0.0;
        if (value <= 0.0 || value >= 1.0 || alpha <= 0.0) { output.write(original, gid); return; }
        uint bin = min(15u, uint(value * 16.0));
        float result = clamp(float(grained.read(sourcePoint).r) / alpha - means[bin], 0.0, 1.0) * alpha;
        output.write(half4(half(result), half(result), half(result), original.a), gid);
    }
    """
}
