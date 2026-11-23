//
// Copyright (c) 2026, Nils Duval
// Licensed under CC BY-NC 4.0. See LICENSE under the root folder.
//
using System;
using System.Text;
using UnityEngine;

namespace Interdigital {
namespace Gltf2 {

/// <summary>
/// Reads material properties that arfcore does not expose: it ignores material extensions when parsing a glTF,
/// so their values are taken from the JSON chunk of the raw GLB. To be removed once arfcore exposes them.
/// </summary>
public static class GltfMaterialExtensions
{
    public const string Anisotropy = "KHR_materials_anisotropy";

    public class AnisotropicMaterial
    {
        public float strength;
        public float rotation;
        public float roughness;
    }

    [Serializable] class JsonAnisotropy { public float anisotropyStrength; public float anisotropyRotation; }
    [Serializable] class JsonExtensions { public JsonAnisotropy KHR_materials_anisotropy; }
    [Serializable] class JsonPbr { public float roughnessFactor = 1f; }
    [Serializable] class JsonMaterial { public JsonPbr pbrMetallicRoughness; public JsonExtensions extensions; }
    [Serializable] class JsonGltf { public JsonMaterial[] materials; }

    /// <summary>
    /// Returns the anisotropy of a material, or null if it has none. A strength of 0, which is also the default
    /// value of the extension, means that the material is not anisotropic.
    /// </summary>
    public static AnisotropicMaterial ReadAnisotropy(byte[] glb, long materialIndex)
    {
        const int headerSize = 12, chunkHeaderSize = 8;
        const uint magicGltf = 0x46546C67, chunkJson = 0x4E4F534A;
        if (glb == null || glb.Length < headerSize + chunkHeaderSize) return null;
        if (BitConverter.ToUInt32(glb, 0) != magicGltf || BitConverter.ToUInt32(glb, headerSize + 4) != chunkJson) return null;
        int length = (int)BitConverter.ToUInt32(glb, headerSize);
        if (length <= 0 || length > glb.Length - headerSize - chunkHeaderSize) return null;

        var gltf = JsonUtility.FromJson<JsonGltf>(Encoding.UTF8.GetString(glb, headerSize + chunkHeaderSize, length));
        if (gltf?.materials == null || materialIndex < 0 || materialIndex >= gltf.materials.Length) return null;
        var material = gltf.materials[materialIndex];
        var anisotropy = material.extensions?.KHR_materials_anisotropy;
        if (anisotropy == null || anisotropy.anisotropyStrength <= 0f) return null;
        return new AnisotropicMaterial {
            strength = Mathf.Clamp01(anisotropy.anisotropyStrength),
            rotation = anisotropy.anisotropyRotation,
            roughness = material.pbrMetallicRoughness != null ? Mathf.Clamp01(material.pbrMetallicRoughness.roughnessFactor) : 1f,
        };
    }
}

}
}
