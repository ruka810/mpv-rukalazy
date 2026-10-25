"""Run offline VapourSynth exports with a binary stdout -> stdin pipe."""

import json
import math
import pathlib
import re
import subprocess
import sys
import tempfile


def checked(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace", **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited with {result.returncode}:\n{result.stderr}\n{result.stdout}")
    return result.stdout


def export(job):
    source_info = json.loads(checked([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=avg_frame_rate,r_frame_rate", "-of", "json", job["source"],
    ]))["streams"][0]
    rate = source_info.get("avg_frame_rate", "0/0")
    if rate in ("0/0", "0/1"):
        rate = source_info["r_frame_rate"]
    num, den = map(int, rate.split("/"))
    if num <= 0 or den <= 0:
        raise RuntimeError(f"Invalid source frame rate: {rate}")

    original = pathlib.Path(job["script"]).resolve()
    # Define mpv's injected globals instead of rewriting a particular assignment.
    header = (
        "import vapoursynth as _capture_vs\n"
        "import sys as _capture_sys\n"
        f"_capture_sys.path.insert(0, {str(original.parent)!r})\n"
        f"container_fps = {num} / {den}\n"
        f"video_in = _capture_vs.core.bs.VideoSource({job['source']!r}, fpsnum={num}, fpsden={den})\n"
    )
    with tempfile.TemporaryDirectory(prefix="mpv-capture-") as temp:
        offline = pathlib.Path(temp) / "offline.vpy"
        offline.write_text(header + original.read_text(encoding="utf-8-sig"), encoding="utf-8")
        # Keep relative model/import paths relative to the original script.
        info = checked([job["vspipe"], "--info", str(offline)], cwd=original.parent)
        fps = re.search(r"FPS:\s*(\d+)\s*/\s*(\d+)", info)
        frames = re.search(r"Frames:\s*(\d+)", info)
        if not fps or not frames:
            raise RuntimeError(f"Cannot read VSPipe output frame count/rate:\n{info}")
        fps_num, fps_den = map(int, fps.groups())
        start = math.floor(job["start"] * fps_num / fps_den)
        # VSPipe --end is inclusive. Never request past the last output frame.
        end = min(int(frames[1]), math.ceil((job["start"] + job["duration"]) * fps_num / fps_den)) - 1
        if start > end:
            raise RuntimeError("The selected range contains no output frames")
        vs_args = [job["vspipe"], "-c", "y4m", "--start", str(start), "--end", str(end), str(offline), "-"]
        with tempfile.TemporaryFile() as errors:
            producer = subprocess.Popen(vs_args, stdout=subprocess.PIPE, stderr=errors, cwd=original.parent)
            try:
                consumer = subprocess.Popen(job["ffmpeg_args"], stdin=producer.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                producer.stdout.close()
                try:
                    _, ff_errors = consumer.communicate()
                finally:
                    if consumer.poll() is None:
                        consumer.kill()
                        consumer.wait()
                if consumer.returncode and producer.poll() is None:
                    producer.terminate()
                vs_status = producer.wait()
            finally:
                producer.stdout.close()
                if producer.poll() is None:
                    producer.kill()
                    producer.wait()
            errors.seek(0)
            vs_errors = errors.read().decode("utf-8", errors="replace")
            if consumer.returncode or vs_status:
                raise RuntimeError(
                    f"FFmpeg exited with {consumer.returncode}:\n{ff_errors.decode('utf-8', errors='replace')}\n"
                    f"VSPipe exited with {vs_status}:\n{vs_errors}"
                )


if __name__ == "__main__":
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    try:
        export(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")))
    except Exception as error:
        print(error, file=sys.stderr)
        sys.exit(1)
