import * as THREE from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { MeshoptDecoder } from "three/addons/libs/meshopt_decoder.module.js";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const canvas = document.getElementById("view");
const img = document.getElementById("seed");
const track = document.getElementById("track");
const hint = document.getElementById("hint");
const steps = [...document.querySelectorAll(".viz__steps span")];
if (!canvas) throw new Error("no canvas");

const renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
renderer.setClearAlpha(0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.15;

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(35, 1, 0.1, 100);

scene.add(new THREE.HemisphereLight(0xffffff, 0xc4c4c4, 1.15));
const key = new THREE.DirectionalLight(0xffffff, 1.7);
key.position.set(2, 3, 4);
scene.add(key);
const fill = new THREE.DirectionalLight(0xffffff, 0.5);
fill.position.set(-3, 1, -3);
scene.add(fill);

let model = null, baseDist = 0, camY = 0;
const uTexMix = { value: 0 }; // 0 = clay, 1 = textured

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableZoom = false;
controls.enablePan = false;
controls.enableDamping = true;
controls.dampingFactor = 0.09;
controls.rotateSpeed = 0.7;
controls.enabled = false;

function fit() {
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w || !h) return;
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}

new GLTFLoader()
  .setMeshoptDecoder(MeshoptDecoder)
  .load("assets/model.glb", (gltf) => {
    model = gltf.scene;
    model.traverse((o) => {
      if (!o.isMesh) return;
      if (!o.geometry.attributes.normal) o.geometry.computeVertexNormals();
      const m = o.material;
      m.metalness = 0;
      m.onBeforeCompile = (sh) => {
        sh.uniforms.uTexMix = uTexMix;
        sh.fragmentShader =
          "uniform float uTexMix;\n" +
          sh.fragmentShader.replace(
            "#include <map_fragment>",
            "#include <map_fragment>\n diffuseColor.rgb = mix(vec3(0.82), diffuseColor.rgb, clamp(uTexMix,0.0,1.0));"
          );
      };
      m.needsUpdate = true;
    });

    const box = new THREE.Box3().setFromObject(model);
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    model.position.sub(center);
    const radius = Math.max(size.x, size.y, size.z) / 2;
    baseDist = (radius / Math.tan((35 / 2) * Math.PI / 180)) * 1.9; // model size
    camY = radius * 0.04;
    camera.position.set(0, camY, baseDist);
    camera.lookAt(0, 0, 0);
    controls.target.set(0, 0, 0);
    scene.add(model);
    fit();
  });

const smooth = (a, b, x) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};
const progress = () => {
  const max = document.documentElement.scrollHeight - window.innerHeight;
  return max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
};

fit();
window.addEventListener("resize", fit);

const YAW = -0.18; // slight turn to the left to match the photo

function tick(t) {
  const p = progress();

  // ---- Phase A (slideshow): image slides up & out, model slides up into center ----
  const slide = smooth(0.0, 0.22, p);
  track.style.transform = `translateY(${(-slide * 50).toFixed(2)}%)`;
  if (img) img.style.opacity = (1 - smooth(0.08, 0.2, p)).toFixed(3);

  // ---- Phase B (rotate-transition): clay -> textured, one turn, ends front ----
  uTexMix.value = smooth(0.34, 0.66, p);
  const turn = smooth(0.26, 0.66, p) * Math.PI * 2;

  // ---- Phase C: orbit the textured model ----
  const orbit = p > 0.9 && !!model;
  controls.enabled = orbit;
  if (orbit) {
    controls.update();
  } else if (model) {
    camera.position.set(0, camY, baseDist);
    camera.lookAt(0, 0, 0);
    const sway = reduced ? 0 : Math.sin(t * 0.0006) * 0.04;
    model.rotation.y = YAW + turn + sway;
  }
  canvas.style.cursor = orbit ? "grab" : "default";
  if (hint) hint.classList.toggle("on", orbit);

  const stage = p < 0.2 ? 0 : uTexMix.value < 0.5 ? 1 : 2;
  steps.forEach((el, i) => el.classList.toggle("on", i === stage));

  renderer.render(scene, camera);
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
