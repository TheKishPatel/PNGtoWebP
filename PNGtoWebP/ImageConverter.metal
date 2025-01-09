//
//  ImageConverter.metal
//  PNGtoWebP
//
//  Created by Kish on 08/01/2025.
//

#include <metal_stdlib>
using namespace metal;

kernel void convertImage(texture2d<float, access::read> inputTexture [[texture(0)]],
                        texture2d<float, access::write> outputTexture [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    // Check if the pixel is within the texture bounds
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }
    
    // Read input pixel - ensure we're preserving exact color values
    float4 color = inputTexture.read(gid);
    
    // Write output pixel without any modification
    outputTexture.write(color, gid);
}
