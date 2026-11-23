//
// Copyright (c) 2026, Nils Duval
// Licensed under CC BY-NC 4.0. See LICENSE under the root folder.
//
// Hair cards: glTF cutout material with KHR_materials_anisotropy (built-in render pipeline).
// Two Kajiya-Kay highlights along the strand direction, with per-strand variation derived from the UVs.
Shader "UnityARF/Hair"
{
    Properties
    {
        _MainTex ("Base color (RGB), strands (A)", 2D) = "white" {}
        _Color ("Base color factor", Color) = (1, 1, 1, 1)
        _Cutoff ("Alpha cutoff", Range(0, 1)) = 0.5
        _ClipThreshold ("Coverage clip (0.5 without MSAA)", Range(0, 1)) = 0.5
        _StrandDirection ("Strand direction in tangent space", Vector) = (0, 1, 0, 0)
        _Roughness ("Roughness", Range(0.05, 1)) = 0.5
        _AnisotropyStrength ("Anisotropy strength", Range(0, 1)) = 1

        _PrimaryColor ("Primary highlight", Color) = (0.17, 0.14, 0.11, 1)
        _SecondaryColor ("Secondary highlight", Color) = (0.11, 0.06, 0.035, 1)
        _PrimaryShift ("Primary shift", Range(-0.5, 0.5)) = 0.06
        _SecondaryShift ("Secondary shift", Range(-0.5, 0.5)) = -0.1
        _StrandNoise ("Per-strand shift", Range(0, 0.5)) = 0.1
        _DiffuseWrap ("Diffuse wrap", Range(0, 1)) = 0.5
    }
    SubShader
    {
        PackageRequirements { "com.unity.render-pipelines.universal" }
        Tags { "RenderPipeline" = "UniversalPipeline" "Queue" = "AlphaTest" "RenderType" = "TransparentCutout" }

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }
            Cull Off
            ZWrite On
            AlphaToMask On

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);

            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _MainTex_TexelSize;
                half4 _Color, _PrimaryColor, _SecondaryColor;
                float _Cutoff, _ClipThreshold, _Roughness, _AnisotropyStrength;
                float _PrimaryShift, _SecondaryShift, _StrandNoise, _DiffuseWrap;
                float4 _StrandDirection;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalWS : TEXCOORD2;
                float3 strandWS : TEXCOORD3;
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                VertexPositionInputs position = GetVertexPositionInputs(v.positionOS.xyz);
                VertexNormalInputs normal = GetVertexNormalInputs(v.normalOS, v.tangentOS);
                o.positionCS = position.positionCS;
                o.positionWS = position.positionWS;
                o.uv = v.uv;
                o.normalWS = normal.normalWS;
                o.strandWS = normal.tangentWS * _StrandDirection.x + normal.bitangentWS * _StrandDirection.y;
                return o;
            }

            // Mipmaps average the strands with the transparent background: compensate so they don't vanish.
            float MipLevel(float2 uv)
            {
                float2 dx = ddx(uv * _MainTex_TexelSize.zw);
                float2 dy = ddy(uv * _MainTex_TexelSize.zw);
                return max(0.0, 0.5 * log2(max(dot(dx, dx), dot(dy, dy))));
            }

            float StrandHighlight(float3 strand, float3 normal, float shift, float3 halfVector, float exponent)
            {
                float3 shifted = normalize(strand + normal * shift);
                float cosine = dot(shifted, halfVector);
                float sine = sqrt(saturate(1.0 - cosine * cosine));
                return smoothstep(-1.0, 0.0, cosine) * pow(sine, exponent);
            }

            half4 frag(Varyings i, FRONT_FACE_TYPE face : FRONT_FACE_SEMANTIC) : SV_Target
            {
                half4 base = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv);
                base.rgb *= _Color.rgb;
                float mip = MipLevel(i.uv);
                float alpha = base.a * (1.0 + mip * 0.5);
                float coverage = saturate((alpha - _Cutoff) / max(fwidth(alpha), 0.0001) + 0.5);
                clip(coverage - _ClipThreshold);

                float3 normal = normalize(i.normalWS) * IS_FRONT_VFACE(face, 1.0, -1.0);
                float3 strand = normalize(i.strandWS);
                float3 view = GetWorldSpaceNormalizeViewDir(i.positionWS);
                Light mainLight = GetMainLight();
                float3 halfVector = normalize(mainLight.direction + view);

                // One value per column across the strands of the atlas.
                float across = dot(i.uv, float2(_StrandDirection.y, -_StrandDirection.x));
                float noise = frac(sin(floor(across * 1024.0) * 12.9898) * 43758.5453) - 0.5;
                // Strand-level detail fades with distance, where it would only alias into noise.
                float detail = saturate(1.0 - mip * 0.4);
                float shift = noise * _StrandNoise * detail;

                float alphaRoughness = max(_Roughness * _Roughness, 0.02);
                float exponent = clamp(2.0 / (alphaRoughness * alphaRoughness) - 2.0, 8.0, 512.0);
                exponent = lerp(exponent * 0.2, exponent, detail);
                float primary = StrandHighlight(strand, normal, _PrimaryShift + shift, halfVector, exponent);
                float secondary = StrandHighlight(strand, normal, _SecondaryShift + shift, halfVector, exponent * 0.3);

                float wrapped = saturate((dot(normal, mainLight.direction) + _DiffuseWrap) / (1.0 + _DiffuseWrap));
                float3 color = base.rgb * (SampleSH(normal) + mainLight.color * wrapped);
                color += mainLight.color * wrapped * _AnisotropyStrength * lerp(0.55, 1.0, detail) *
                    (primary * _PrimaryColor.rgb + secondary * _SecondaryColor.rgb);
                return half4(color, coverage);
            }
            ENDHLSL
        }
    }
    SubShader
    {
        Tags { "Queue" = "AlphaTest" "RenderType" = "TransparentCutout" "IgnoreProjector" = "True" }

        Pass
        {
            Tags { "LightMode" = "ForwardBase" }
            Cull Off
            ZWrite On
            AlphaToMask On

            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0
            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            sampler2D _MainTex;
            float4 _MainTex_TexelSize;
            fixed4 _Color, _PrimaryColor, _SecondaryColor;
            float _Cutoff, _ClipThreshold, _Roughness, _AnisotropyStrength;
            float _PrimaryShift, _SecondaryShift, _StrandNoise, _DiffuseWrap;
            float4 _StrandDirection;

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                float4 tangent : TANGENT;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 worldPos : TEXCOORD1;
                float3 normal : TEXCOORD2;
                float3 strand : TEXCOORD3;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                o.normal = UnityObjectToWorldNormal(v.normal);
                float3 tangent = UnityObjectToWorldDir(v.tangent.xyz);
                float3 bitangent = cross(o.normal, tangent) * v.tangent.w * unity_WorldTransformParams.w;
                o.strand = tangent * _StrandDirection.x + bitangent * _StrandDirection.y;
                return o;
            }

            // Mipmaps average the strands with the transparent background: compensate so they don't vanish.
            float MipLevel(float2 uv)
            {
                float2 dx = ddx(uv * _MainTex_TexelSize.zw);
                float2 dy = ddy(uv * _MainTex_TexelSize.zw);
                return max(0.0, 0.5 * log2(max(dot(dx, dx), dot(dy, dy))));
            }

            float StrandHighlight(float3 strand, float3 normal, float shift, float3 halfVector, float exponent)
            {
                float3 shifted = normalize(strand + normal * shift);
                float cosine = dot(shifted, halfVector);
                float sine = sqrt(saturate(1.0 - cosine * cosine));
                return smoothstep(-1.0, 0.0, cosine) * pow(sine, exponent);
            }

            fixed4 frag(v2f i, fixed facing : VFACE) : SV_Target
            {
                fixed4 base = tex2D(_MainTex, i.uv);
                base.rgb *= _Color.rgb;
                float mip = MipLevel(i.uv);
                float alpha = base.a * (1.0 + mip * 0.5);
                float coverage = saturate((alpha - _Cutoff) / max(fwidth(alpha), 0.0001) + 0.5);
                clip(coverage - _ClipThreshold);

                float3 normal = normalize(i.normal) * (facing > 0 ? 1.0 : -1.0);
                float3 strand = normalize(i.strand);
                float3 view = normalize(UnityWorldSpaceViewDir(i.worldPos));
                float3 light = normalize(_WorldSpaceLightPos0.xyz);
                float3 halfVector = normalize(light + view);

                // One value per column across the strands of the atlas.
                float across = dot(i.uv, float2(_StrandDirection.y, -_StrandDirection.x));
                float noise = frac(sin(floor(across * 1024.0) * 12.9898) * 43758.5453) - 0.5;
                // Strand-level detail fades with distance, where it would only alias into noise.
                float detail = saturate(1.0 - mip * 0.4);
                float shift = noise * _StrandNoise * detail;

                float alphaRoughness = max(_Roughness * _Roughness, 0.02);
                float exponent = clamp(2.0 / (alphaRoughness * alphaRoughness) - 2.0, 8.0, 512.0);
                exponent = lerp(exponent * 0.2, exponent, detail);
                float primary = StrandHighlight(strand, normal, _PrimaryShift + shift, halfVector, exponent);
                float secondary = StrandHighlight(strand, normal, _SecondaryShift + shift, halfVector, exponent * 0.3);

                float wrapped = saturate((dot(normal, light) + _DiffuseWrap) / (1.0 + _DiffuseWrap));
                float3 ambient = ShadeSH9(float4(normal, 1.0));
                float3 color = base.rgb * (ambient + _LightColor0.rgb * wrapped);
                color += _LightColor0.rgb * wrapped * _AnisotropyStrength *
                    lerp(0.55, 1.0, detail) *
                    (primary * _PrimaryColor.rgb + secondary * _SecondaryColor.rgb);
                return fixed4(color, coverage);
            }
            ENDCG
        }
    }
    Fallback "Transparent/Cutout/Diffuse"
}
