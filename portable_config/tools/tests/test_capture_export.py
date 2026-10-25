r"""Integration checks using real mpv Lua callbacks, FFmpeg, libplacebo and VSPipe.

Run from the portable root: .\python.exe portable_config/tools/tests/test_capture_export.py
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parent))
from save_dialog_driver import save_as

ROOT = Path(__file__).resolve().parents[3]
CONFIG = ROOT / "portable_config"


def run(args, **kwargs):
    result = subprocess.run([str(x) for x in args], capture_output=True, timeout=180, **kwargs)
    if result.returncode:
        raise AssertionError(result.stdout.decode("utf-8", "replace") + result.stderr.decode("utf-8", "replace"))
    return result.stdout


class CaptureExportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="mpv-export-test-")
        cls.work = Path(cls.temp.name)
        cls.source = cls.work / "source [a,b] ' 100% 中文.mkv"
        run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=160x90:r=12:d=4",
             "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-c:v", "libx264", "-c:a", "aac", cls.source])
        cls.vpy = cls.work / "double.vpy"
        cls.vpy.write_text("import vapoursynth as vs\nclip = vs.core.std.Interleave([video_in, video_in])\nclip.set_output()\n")
        cls.shader = cls.work / "invert_x2.glsl"
        cls.shader.write_text("//!HOOK MAIN\n//!BIND HOOKED\n//!DESC Test inversion\nvec4 hook() { return vec4(1.0 - HOOKED_tex(HOOKED_pos).rgb, 1.0); }\n")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def export(self, name, vf, shaders, finish=2, output=True, **extra):
        destination = self.work / name
        job = dict(source=str(self.source), output=str(destination) if output else None, start=1, finish=finish,
                   vf=vf, shaders=shaders, config_dir=CONFIG.as_posix(), script=str(CONFIG / "scripts/capture_tools.lua"), **extra)
        job_path = self.work / "job.json"
        job_path.write_text(json.dumps(job), encoding="utf-8")
        env = dict(os.environ, CAPTURE_TEST_JOB=str(job_path))
        run([ROOT / "mpv.com", "--no-config", f"--config-dir={CONFIG}", "--load-scripts=no", "--idle=yes",
             "--vo=null", "--ao=null", "--input-terminal=no", f"--script={Path(__file__).with_name('capture_harness.lua')}"], env=env)
        self.assertFalse(list((CONFIG / "tools").glob("capture_shader_*.tmp")))
        self.assertFalse(list((CONFIG / "tools").glob("capture_vs_*.tmp")))
        if not output:
            return
        info = json.loads(run(["ffprobe", "-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", destination]))
        video = next(stream for stream in info["streams"] if stream["codec_type"] == "video")
        self.assertLess(abs(float(info["format"]["duration"]) - (finish - 1)), 0.15)
        self.assertLess(abs(float(video.get("start_time", 0))), 0.15)
        self.assertTrue(any(stream["codec_type"] == "audio" for stream in info["streams"]))
        return destination, video

    def test_vf_and_shader(self):
        dest, video = self.export("vf.mp4", [{"name": "lavfi", "params": {"graph": "hflip"}}], [str(self.shader)])
        self.assertEqual((video["width"], video["height"]), (320, 180))
        self.assertEqual(int(video["nb_read_frames"]), 12)
        actual = run(["ffmpeg", "-v", "error", "-i", dest, "-frames:v", "1", "-vf", "scale=160:90", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"])
        baseline = run(["ffmpeg", "-v", "error", "-ss", "1", "-i", self.source, "-frames:v", "1", "-vf", "hflip,negate", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"])
        self.assertLess(sum(abs(a-b) for a, b in zip(actual, baseline)) / len(actual), 14)

    def test_vs_and_shader(self):
        _, video = self.export("vs.mkv", [{"name": "vapoursynth", "params": {"file": str(self.vpy)}}], [str(self.shader)])
        self.assertEqual((video["width"], video["height"]), (320, 180))
        self.assertEqual(video["r_frame_rate"], "24/1")
        self.assertEqual(int(video["nb_read_frames"]), 24)

    def test_vs_only_at_end_of_source(self):
        _, video = self.export("vs-only.mp4", [{"name": "vapoursynth", "params": {"file": str(self.vpy)}}], [], finish=4)
        self.assertEqual(int(video["nb_read_frames"]), 72)

    def test_disabled_vs_and_cancel_cleanup(self):
        vf = [{"name": "vapoursynth", "enabled": False, "params": {"file": "missing.vpy"}}]
        self.export("cancel.mkv", vf, [str(self.shader)], output=False)
        _, video = self.export("disabled.webm", vf, [str(self.shader)])
        self.assertEqual(int(video["nb_read_frames"]), 12)

    def test_current_shader_bundle(self):
        shaders = [str(CONFIG / "shaders" / path) for path in [
            "QCOM/QCOM_SGEDS_ms_RT.glsl", "EDI/nnedi3_nns64_win8x4.glsl",
            "FSRCNNX/FSRCNNX_x2_16_0_4_1.glsl", "Anime4K/Anime4K_Restore_CNN_L.glsl",
            "ESRGAN/k7_modernAnime_DT_FHD_x2.glsl",
        ]]
        _, video = self.export("current-shaders.mkv", [], shaders)
        self.assertEqual((video["width"], video["height"]), (320, 180))

    def test_external_subtitle_timing(self):
        subtitles = self.work / "external.srt"
        subtitles.write_text("1\n00:00:00,100 --> 00:00:00,400\nbefore\n\n2\n00:00:01,200 --> 00:00:01,600\ninside\n", encoding="utf-8")
        tracks = [{"type": "sub", "external": True, "external-filename": str(subtitles), "codec": "subrip"}]
        dest, _ = self.export("subtitles.mkv", [{"name": "vapoursynth", "params": {"file": str(self.vpy)}}], [], tracks=tracks)
        exported = run(["ffmpeg", "-v", "error", "-i", dest, "-map", "0:s:0", "-f", "srt", "-"]).decode()
        self.assertIn("inside", exported)
        self.assertNotIn("before", exported)
        self.assertIn("00:00:00,200", exported)

    def test_consumer_failure_reports_both_processes(self):
        job_path = self.work / "failure.json"
        job_path.write_text(json.dumps(dict(source=str(self.source), script=str(self.vpy), vspipe=str(ROOT / "VSPipe.exe"),
            start=1, duration=1, ffmpeg_args=["ffmpeg", "-v", "error", "-i", "pipe:0", "-vf", "capture_no_such_filter", "-f", "null", "-"])), encoding="utf-8")
        result = subprocess.run([str(ROOT / "python.exe"), str(CONFIG / "tools/capture_vs.py"), str(job_path)], capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"FFmpeg exited", result.stderr)
        self.assertIn(b"VSPipe exited", result.stderr)
        self.assertIn(b"capture_no_such_filter", result.stderr)

    def test_real_save_dialog_returns_utf8_from_cp936_console(self):
        destination = self.work / "战双_中文导出 [a,b] ' 100%.mkv"
        script = str(CONFIG / "tools/select_save_path.ps1").replace("'", "''")
        command = "[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936); & '" + script + "' -Mode video"
        process = subprocess.Popen(["powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-STA",
            "-ExecutionPolicy", "Bypass", "-Command", command], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            save_as(destination)
            output, error = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, error)
            actual = Path(output.decode("utf-8"))
            self.assertEqual(actual.name, destination.name)
            self.assertTrue(actual.parent.samefile(destination.parent))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


if __name__ == "__main__":
    unittest.main(verbosity=2)
