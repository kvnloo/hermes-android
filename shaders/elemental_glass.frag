// Elemental glass: a translucent pane of natural material over the wallpaper.
//
// Lighting is ported from elemental-ui `shaders/elemental_surface.wgsl`
// (GGX distribution, Smith-Schlick visibility, Schlick Fresnel, Reinhard), so
// stone packs relight exactly the way they do on web, native and Hyprland.
// The difference is the output: elemental-ui paints an opaque slab, while this
// shader emits a premultiplied, mostly transparent pane, so the blurred
// wallpaper stays visible through the stone, water or crystal.
//
// Copyright (c) 2026 Kevin Rajan. Lighting model and packs: GPL-3.0-only
// (third_party/elemental-ui/LICENSE).
#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;        // painted area, logical px
uniform float uTilePx;     // on-screen size of one material tile, logical px
uniform float uTime;       // seconds; drives water and the light drift
uniform vec4 uLight;       // xyz toward the light, w intensity
uniform vec4 uBody;        // rgb body colour (linear), a body opacity
uniform vec4 uParams;      // x kind (0 pack, 1 water, 2 quartz), y relief, z sheen gain, w exposure
uniform vec2 uOffset;      // origin of this pane in screen space, logical px

uniform sampler2D uBase;
uniform sampler2D uNormal;
uniform sampler2D uRough;

out vec4 fragColor;

const float PI = 3.14159265;

vec3 srgbToLinear(vec3 c) {
  return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 linearToSrgb(vec3 c) {
  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec2 hash2(vec2 p) {
  p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453);
}

float valueNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash2(i).x;
  float b = hash2(i + vec2(1.0, 0.0)).x;
  float c = hash2(i + vec2(0.0, 1.0)).x;
  float d = hash2(i + vec2(1.0, 1.0)).x;
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Water surface height: a few drifting octaves, slow enough to read as calm.
float waterHeight(vec2 p, float t) {
  float h = 0.0;
  h += 0.55 * valueNoise(p * 1.1 + vec2(t * 0.07, t * 0.05));
  h += 0.30 * valueNoise(p * 2.3 - vec2(t * 0.11, -t * 0.06));
  h += 0.15 * valueNoise(p * 4.7 + vec2(-t * 0.16, t * 0.13));
  return h;
}

struct Surface {
  vec3 base;     // linear
  vec3 normal;   // tangent space, +z toward viewer
  float rough;
  float glint;   // extra highlight for crystal edges / caustic lines
};

Surface packSurface(vec2 uv) {
  vec2 st = fract(uv);
  Surface s;
  s.base = srgbToLinear(texture(uBase, st).rgb);
  vec3 n = texture(uNormal, st).xyz * 2.0 - 1.0;
  s.normal = normalize(vec3(n.xy * uParams.y, n.z));
  s.rough = clamp(texture(uRough, st).r, 0.045, 1.0);
  s.glint = 0.0;
  return s;
}

Surface waterSurface(vec2 uv, float t) {
  float e = 0.035;
  float h = waterHeight(uv, t);
  float hx = waterHeight(uv + vec2(e, 0.0), t) - h;
  float hy = waterHeight(uv + vec2(0.0, e), t) - h;
  Surface s;
  s.base = uBody.rgb;
  s.normal = normalize(vec3(-hx / e * 0.10 * uParams.y, -hy / e * 0.10 * uParams.y, 1.0));
  s.rough = 0.08;
  // Caustic lines: thin bright ridges where the height field folds.
  float ridge = 1.0 - abs(2.0 * fract(h * 3.0 + t * 0.02) - 1.0);
  s.glint = smoothstep(0.86, 1.0, ridge) * 0.7 * valueNoise(uv * 0.7 + t * 0.03);
  return s;
}

Surface quartzSurface(vec2 uv) {
  // Voronoi facets: every cell is a flat crystal face with its own tilt.
  vec2 cell = floor(uv * 2.2);
  vec2 f = fract(uv * 2.2);
  float best = 8.0;
  float second = 8.0;
  vec2 bestId = vec2(0.0);
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 o = vec2(float(i), float(j));
      vec2 p = o + hash2(cell + o);
      float d = length(p - f);
      if (d < best) {
        second = best;
        best = d;
        bestId = cell + o;
      } else if (d < second) {
        second = d;
      }
    }
  }
  vec2 tilt = hash2(bestId * 1.7) * 2.0 - 1.0;
  Surface s;
  s.base = uBody.rgb * (0.92 + 0.16 * hash2(bestId).y);
  s.normal = normalize(vec3(tilt * 0.38 * uParams.y, 1.0));
  s.rough = 0.12;
  // Facet edges catch light like cut glass.
  float edge = 1.0 - smoothstep(0.0, 0.035, second - best);
  s.glint = edge * 0.45;
  return s;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 screen = frag + uOffset;
  vec2 uv = screen / uTilePx;
  float kind = uParams.x;
  float t = uTime;

  Surface s;
  if (kind < 0.5) {
    s = packSurface(uv);
  } else if (kind < 1.5) {
    s = waterSurface(uv, t);
  } else {
    s = quartzSurface(uv);
  }

  vec3 n = s.normal;
  vec3 l = normalize(uLight.xyz);
  vec3 v = vec3(0.0, 0.0, 1.0);
  vec3 h = normalize(l + v);
  float nDotL = max(dot(n, l), 0.0);
  float nDotH = max(dot(n, h), 0.0);
  float nDotV = max(dot(n, v), 1e-4);

  float a = s.rough * s.rough;
  float a2 = a * a;
  float dDenom = nDotH * nDotH * (a2 - 1.0) + 1.0;
  float distribution = a2 / (PI * dDenom * dDenom);
  float k = a * 0.5;
  float visibility = 1.0 / ((nDotL * (1.0 - k) + k) * (nDotV * (1.0 - k) + k) * 4.0);
  float fresnel = 0.04 + 0.96 * pow(1.0 - max(dot(h, v), 0.0), 5.0);
  float specular = distribution * visibility * fresnel;

  float radiance = uLight.w;
  vec3 diffuse = s.base * (1.0 - fresnel) / PI * radiance * nDotL;
  vec3 ambient = s.base * 0.35;
  vec3 body = (diffuse + ambient) * uParams.w;
  body = body / (vec3(1.0) + body);

  // Light the pane rather than darken it: specular and glints add white light,
  // the body adds only a thin veil of the material's own colour.
  // Specular peaks of smooth water/crystal are unbounded under GGX; cap them
  // so a highlight reads as a glint, never as a white blotch.
  float highlight = min(specular * radiance * nDotL, 1.0) * 0.6;
  float sheen = clamp((highlight + s.glint) * uParams.z, 0.0, 1.0);
  float bodyAlpha = uBody.a;
  vec3 colour = linearToSrgb(body);
  vec3 premul = colour * bodyAlpha + vec3(1.0) * sheen * (1.0 - bodyAlpha);
  float alpha = clamp(bodyAlpha + sheen * (1.0 - bodyAlpha), 0.0, 1.0);
  fragColor = vec4(premul, alpha);
}
