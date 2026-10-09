"""Run native LightX2V image editing with memory-bounded MPS conditioning.

The current streaming text encoder omits vision weights and rejects i2i.
Reuse its language streaming and the ordinary native vision forward, loading
only the vision tower while encoding references. No checkout is modified.
"""
import runpy


def enable_mps_editing():
    import torch
    from lightx2v.common.offload.safetensors_checkpoint import SafetensorsCheckpoint
    from lightx2v.models.input_encoders.hf.qwen_image_21 import qwen3vl_mps
    from lightx2v.models.input_encoders.hf.qwen_image_21.qwen3vl import Qwen3VLVision, QwenImage21TextEncoder
    from lightx2v.models.runners.qwen_image_21.qwen_image_21_runner import QwenImage21Runner
    from lightx2v.utils.envs import GET_DTYPE

    class VisionEncoder:
        def __init__(self, path, config):
            self.checkpoint = SafetensorsCheckpoint(path)
            self.config = config

        def forward(self, pixels, grid):
            vision = Qwen3VLVision(self.config)
            names = {name for name in self.checkpoint.weight_map if name.startswith("model.visual.")}
            weights = self.checkpoint.load_tensors(names)
            vision.load({name: tensor.to(device="mps", dtype=GET_DTYPE()) for name, tensor in weights.items()})
            del weights
            try:
                return vision.forward(pixels, grid)
            finally:
                del vision
                torch.mps.empty_cache()

    class ImageEditingEncoder(qwen3vl_mps.QwenImage21MpsTextEncoder):
        def _load_weights(self, path, config):
            super()._load_weights(path, config)
            self.add_module("vision", VisionEncoder(path, self.model_config["vision_config"]))

        @torch.inference_mode()
        def infer(self, prompt, images=None):
            return QwenImage21TextEncoder.infer(self, prompt, images)

    validate_streaming = QwenImage21Runner._validate_mps_streaming_config

    def validate(config):
        # All device, offload, precision and parallel constraints still apply.
        validate_streaming(dict(config, task="t2i") if config.get("task") == "i2i" else config)

    QwenImage21Runner._validate_mps_streaming_config = staticmethod(validate)
    qwen3vl_mps.QwenImage21MpsTextEncoder = ImageEditingEncoder


if __name__ == "__main__":
    enable_mps_editing()
    runpy.run_module("lightx2v.infer", run_name="__main__")
