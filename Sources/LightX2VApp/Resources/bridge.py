#!/usr/bin/env python3
"""LightX2V APP process supervisor; all stdout is NDJSON."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

# Bundled adapters must never add bytecode files inside the signed APP bundle.
sys.dont_write_bytecode = True

TURBO_STEPS = 8
TURBO_SIGMAS = [1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568]


def emit(kind, **fields):
    print(json.dumps({"type": kind, **fields}, ensure_ascii=False), flush=True)


def load_request(path):
    with open(path, encoding="utf-8") as f:
        request = json.load(f)
    for key in ("repository", "model", "config"):
        value = request.get(key)
        if not isinstance(value, str) or not Path(value).is_absolute():
            raise ValueError(f"{key} must be an absolute path")
    repo, model, config = (Path(request[k]) for k in ("repository", "model", "config"))
    if not (repo / "lightx2v/infer.py").is_file():
        raise ValueError("Invalid LightX2V path: lightx2v/infer.py not found")
    for folder in ("transformer", "text_encoder", "vae", "scheduler", "processor"):
        if not (model / folder).is_dir():
            raise ValueError(f"Model directory missing or symlink broken: {folder}")
    with (model / "model_index.json").open(encoding="utf-8") as f:
        metadata = json.load(f)
    if metadata.get("sample_sigmas") != TURBO_SIGMAS:
        raise ValueError("Choose Qwen-Image-2.1-Turbo weights; the 8-step sampling configuration does not match")
    with config.open(encoding="utf-8") as f:
        cfg = json.load(f)
    if cfg.get("infer_steps") != TURBO_STEPS or cfg.get("sigmas") != TURBO_SIGMAS:
        raise ValueError("Choose qwen_image_21_turbo.json: Turbo requires fixed 8-step sampling")
    if cfg.get("attn_type") != "torch_sdpa_mps":
        raise ValueError("Choose an MPS configuration using torch_sdpa_mps")
    if cfg.get("do_time_shift") is not False:
        raise ValueError("Turbo configuration requires do_time_shift=false")
    if cfg.get("enable_cfg") is not False or cfg.get("sample_guide_scale") != 1.0:
        raise ValueError("Turbo configuration requires CFG disabled and sample_guide_scale=1.0")
    return request, cfg


def environment(request):
    env = os.environ.copy()
    # Keep base.sh semantics while selecting the Python explicitly in the app.
    env.update({
        "PLATFORM": "mps", "PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8",
        "PYTHONPATH": request["repository"] + os.pathsep + env.get("PYTHONPATH", ""),
        "MOONCAKE_CONFIG_PATH": str(Path(request["repository"]) / "configs/mooncake_config.json"),
        "TOKENIZERS_PARALLELISM": "false", "PYTORCH_CUDA_ALLOC_CONF": "expandable_segments:True",
        "PYTORCH_ALLOC_CONF": "expandable_segments:True", "DTYPE": "BF16",
        "SENSITIVE_LAYER_DTYPE": "None", "PROFILING_DEBUG_LEVEL": "2", "LOGURU_COLORIZE": "NO",
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
        "PATH": str(Path(sys.executable).parent) + os.pathsep + env.get("PATH", "/usr/bin:/bin"),
    })
    return env


def arguments(request, config_path):
    prompt = request.get("prompt", "")
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 20000:
        raise ValueError("Enter a prompt between 1 and 20000 characters.")
    resolution = request.get("resolution")
    if resolution is not None:
        if type(resolution) is not int or resolution not in (512, 1024, 2048) or any(request.get(k) is not None for k in ("width", "height")):
            raise ValueError("Choose 512, 1K or 2K for adaptive mode; width and height are not required.")
        size_args = ["--resolution", str(resolution)]
        if request.get("aspectRatio"):
            from prompt_enhancement import ratio_value
            ratio_value(request["aspectRatio"])
            size_args += ["--aspect_ratio", request["aspectRatio"]]
    else:
        for key in ("width", "height"):
            n = request.get(key)
            if type(n) is not int or not 256 <= n <= 2752 or n % 32:
                raise ValueError("Width and height must be multiples of 32 between 256 and 2752.")
        size_args = ["--size", str(request["height"]), str(request["width"])]
    seed = request.get("seed")
    if type(seed) is not int or not 0 <= seed <= 4294967295:
        raise ValueError("Seed must be between 0 and 4294967295.")
    output = request.get("output", "")
    if not Path(output).is_absolute() or Path(output).suffix.lower() != ".png":
        raise ValueError("Output must be an absolute PNG path")
    images = request.get("inputImages", [])
    if not isinstance(images, list) or len(images) > 8:
        raise ValueError("You can add up to 8 images.")
    paths = []
    for image in images:
        if not isinstance(image, dict) or not isinstance(image.get("path"), str):
            raise ValueError("Invalid input image record")
        path = Path(image["path"])
        # Relative safe snapshot names avoid CLI comma splitting even when the
        # user's workspace itself contains commas, Unicode or spaces.
        if not path.is_absolute() or path.parent != Path(output).parent / "inputs" or "," in path.name:
            raise ValueError("Input images must be stored in the current task inputs directory")
        from PIL import Image
        with Image.open(path) as reference:
            reference.verify()
        paths.append("inputs/" + path.name)
    # CLI expects HEIGHT WIDTH, whereas the interface displays WIDTH × HEIGHT.
    cmd = [sys.executable, "-u", "-m", "lightx2v.infer",
            "--model_cls", "qwen_image_21", "--task", "i2i" if images else "t2i",
            "--model_path", request["model"], "--config_json", str(config_path),
            "--prompt", prompt, *size_args,
            "--seed", str(seed), "--save_result_path", output]
    if paths:
        cmd += ["--image_path", ",".join(paths)]
    return cmd


def validate_image(path, expected_width=None, expected_height=None):
    # Decode as well as check metadata: a truncated PNG is not a completed run.
    from PIL import Image
    with Image.open(path) as im:
        im.load()
        if im.format != "PNG" or any(n < 32 or n % 32 for n in im.size):
            raise RuntimeError("Generated image is not a valid PNG or its dimensions are not aligned to 32 pixels")
        if expected_width is not None and im.size != (expected_width, expected_height):
            raise RuntimeError(f"Output dimensions do not match: {im.size}, expected {expected_width} × {expected_height}")
        return im.size


class RunCancelled(Exception):
    pass


class ChildSupervisor:
    """One process group at a time across both stages, with shared cancellation."""
    def __init__(self):
        self.child = None
        self.cancelled = False
        self.finished = threading.Event()
        self.old_handlers = {sig: signal.signal(sig, self.cancel) for sig in (signal.SIGTERM, signal.SIGINT)}
        self.parent = os.getppid()
        threading.Thread(target=self.watch_parent, daemon=True).start()

    @staticmethod
    def stop_group(child, sig):
        # A child can exit before its descendants close inherited output pipes.
        # Terminate the owned group even in that case; no process-name matching.
        if child:
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                pass

    def cancel(self, signum, frame):
        if self.cancelled:
            return
        self.cancelled = True
        child = self.child
        self.stop_group(child, signal.SIGTERM)
        timer = threading.Timer(3, lambda: self.stop_group(child, signal.SIGKILL) if self.child is child else None)
        timer.daemon = True
        timer.start()

    def watch_parent(self):
        while not self.finished.wait(1):
            if os.getppid() != self.parent:
                os.kill(os.getpid(), signal.SIGTERM)
                return

    def check_cancelled(self):
        if self.cancelled:
            raise RunCancelled()

    def spawn(self, cmd, **kwargs):
        self.check_cancelled()
        child = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, start_new_session=True, **kwargs)
        self.child = child
        if self.cancelled:
            self.stop_group(child, signal.SIGKILL)
        return child

    def release(self, child):
        self.stop_group(child, signal.SIGKILL)
        child.wait()
        if child.stdout:
            child.stdout.close()
        if self.child is child:
            self.child = None

    def close(self):
        self.finished.set()
        if self.child:
            self.release(self.child)
        for sig, handler in self.old_handlers.items():
            signal.signal(sig, handler)


def run(request, cfg):
    destination = Path(request["output"]).parent
    destination.mkdir(parents=True, exist_ok=True)
    config_path = destination / "config.json"
    # Validate original inputs before launching either model or modifying output.
    arguments(request, config_path)
    if Path(request["output"]).exists():
        raise ValueError("Output file already exists; create a new generation task")
    started = time.monotonic()
    inference_started = None
    supervisor = ChildSupervisor()
    try:
        if request.get("promptEnhancement") is not None:
            from prompt_enhancement import run_enhancement
            request = run_enhancement(request, destination, emit, supervisor)
        supervisor.check_cancelled()
        cmd = arguments(request, config_path)
        config_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
        (destination / "invocation.json").write_text(json.dumps({"argv": cmd, "cwd": str(destination)}, ensure_ascii=False, indent=2), encoding="utf-8")
        inference_started = time.monotonic()
        emit("inference_started", startedAt=time.time())
        emit("status", message="Loading model", phase="loading")
        tail = []
        with (destination / "inference.log").open("w", encoding="utf-8") as log:
            child = supervisor.spawn(cmd, cwd=str(destination), env=environment(request), stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", bufsize=1)
            for raw in child.stdout:
                line = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", raw).rstrip("\r\n")
                log.write(line + "\n")
                log.flush()
                tail = (tail + [line])[-30:]
                emit("log", message=line)
                step = re.search(r"step_index:\s*(\d+)\s*/\s*(\d+)", line)
                if step:
                    emit("step", step=int(step[1]), total=int(step[2]))
                elif "Run VAE Decoder" in line:
                    emit("status", message="Decoding image", phase="decoding")
                elif "Run Encoders" in line:
                    emit("status", message="Encoding prompt", phase="encoding")
            code = child.wait()
            supervisor.release(child)
        supervisor.check_cancelled()
        if code != 0:
            raise RuntimeError(f"Inference process exited ({code})\n" + "\n".join(tail[-12:]))
        width, height = validate_image(request["output"], request.get("width"), request.get("height"))
        emit("done", status="completed", image=request["output"], width=width, height=height, duration=time.monotonic() - started,
             inferenceDuration=time.monotonic() - inference_started)
        return 0
    except BaseException:
        if supervisor.cancelled:
            emit("done", status="cancelled", message="Generation stopped", duration=time.monotonic() - started,
                 inferenceDuration=time.monotonic() - inference_started if inference_started is not None else None)
            return 130
        raise
    finally:
        supervisor.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["run"])
    parser.add_argument("request")
    args = parser.parse_args()
    try:
        request, cfg = load_request(args.request)
        return run(request, cfg)
    except BaseException as exc:
        emit("error", message=str(exc))
        emit("done", status="failed", message=str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
