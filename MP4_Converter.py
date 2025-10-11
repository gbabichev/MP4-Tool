import sys
import os
import shutil
import subprocess
#import requests
import time
import tempfile
import json
import threading
import platform
import builtins
from time import sleep
from natsort import natsorted

"""
George Babichev (and lots of chat gippity :)) 
May 2025
2.0

~~~ Usage ~~~
python MP4_Converter.py inputFolder outputFolder (remux/encode) (true/false)
-- inputFolder: path to folder with video files. Note, these files will be deleted after processing. 
-- outputFolder: path to folder where processed video files will be placed.
-- remux/encode.
--- Remux: Takes existing MKV files, strips out the headers (usually trash info like who the ripper is)
--- Encode: Re-Encodes the video to H265 with my settings (visible in the script)
-- True/False
--- True: Creates a Subfolder for each processed video. This is useful for SabNZB scripts.
--- False: Use false when running manually since create subfolder is annoying. 

# Windows PlexBeast
# Use the PlexBeast script that calls this one from SAB.
#processFolder(sys.argv[1], "D:\\Downloads\\Downloaded", "encode", create_subfolders=True)

# Windows manual run
#processFolder("D:\\copy", "D:\\code", "remux", create_subfolders=False)

# Mac
#processFolder("copy", "code", firstRun="encode", create_subfolders=False)

~~~ Things for testing ~~~
# Cuts 30 seconds out of a video, keeps all tracks
# including subs. Use for test encoding to make it quick.
ffmpeg -i test.mkv -ss 30 -t 60 -map 0 -c copy out.mkv

~~~ How to Install (Mac) ~~~
install brew 
brew install pyenv
pyenv install 3.13
echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.zshrc
echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.zshrc
echo 'eval "$(pyenv init - zsh)"' >> ~/.zshrc
restart shell
pip install requests natsort
brew install ffmpeg

~~~ How to Install (Windows) ~~~
Ensure you have python 3.12+ and it's in the $PATH
install the requests and natsort modules.
Ensure you have FFMPEG installed and it's in the $PATH

"""

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOGFILE = os.path.join(SCRIPT_DIR, "MP4_Converter.log")

def print(*args, **kwargs):
    # Print to console as normal
    builtins.print(*args, **kwargs)
    # Append the same message to the log file
    with open(LOGFILE, "a", encoding="utf-8") as f:
        builtins.print(*args, **kwargs, file=f)

OS_name = platform.system()
# Windows, Darwin, other?

# Define output symbols pretty = unicode, basic = ASCII
# SAB Scripts don't support pretty, so will default Windows to basic. 
if OS_name == "Darwin":
    symbolType = "pretty"
else:
    symbolType = "basic"

if symbolType == "pretty":
    SYMBOL_SUCCESS = "✅ "
    SYMBOL_ERROR = "❌ "
    SYMBOL_INFO = "ℹ️ "
    SYMBOL_WARNING = "⚠️ "
    SYMBOL_FRAME1 = "⌛"
    SYMBOL_FRAME2 = "⏳"
    SYMBOL_FINAL = "🚀"
else:
    SYMBOL_SUCCESS = "[+] "
    SYMBOL_ERROR = "[X] "
    SYMBOL_INFO = "[i]"
    SYMBOL_WARNING = "[!]"
    SYMBOL_FRAME1 = "[:]"
    SYMBOL_FRAME2 = "[.]"
    SYMBOL_FINAL = "[!!!]"

totalRunTime = 0

def show_time(seconds):
    global totalRunTime
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    if hours > 0:
        print(f"{SYMBOL_INFO} Completed in {hours} hour(s), {minutes} minute(s)")
        totalRunTime += seconds
    else:
        minutes_only = round(seconds / 60, 1)
        print(f"{SYMBOL_INFO} Completed in {minutes_only} minute(s)")
        totalRunTime += seconds

def check_if_process_running(process_name):
    try:
        # Execute tasklist command to list all running processes
        result = subprocess.run(['tasklist'], capture_output=True, text=True)
        # Check if the process name exists in the output
        if process_name.lower() in result.stdout.lower():
            print(f"{SYMBOL_WARNING} Process {process_name} is running. Sleeping 10 seconds & trying again")
            sleep(10)
            check_if_process_running(process_name)
        else:
            print(f"{SYMBOL_INFO} Process {process_name} is not running. Continuing...")
            return False
    except Exception as e:
        print(f"Error checking process: {e}")
        return False

def hourglass_animation(stop_event, videoName, tempFile):
    start_time = time.time()
    frames = [SYMBOL_FRAME1, SYMBOL_FRAME2]
    fileName = os.path.basename(videoName)

    while not stop_event.is_set():
        elapsed_time = time.time() - start_time
        try:
            original_file_size = round(os.path.getsize(videoName) / (1024 * 1024))
        except Exception:
            original_file_size = 0
        try:
            new_file_size = round(os.path.getsize(tempFile) / (1024 * 1024))
        except Exception:
            new_file_size = 0

        for frame in frames:
            if stop_event.is_set():
                break
            print(
                f"\r{frame} Processing: {fileName} | "
                f"Elapsed Time: {elapsed_time:.1f}s | "
                f"Original Size: {original_file_size}MB | "
                f"New Size: {new_file_size}MB",
                end="",
                flush=True)
            sleep(0.5)

    eraseValue = len(fileName) + 100
    print("\r" + " " * eraseValue, end="\r", flush=True)

def probe_streams(input_file, select_streams=None):
    """General ffprobe wrapper."""
    cmd = [
        "ffprobe", "-v", "error", "-show_streams", "-print_format", "json", input_file
    ]
    if select_streams:
        cmd.insert(4, "-select_streams")
        cmd.insert(5, select_streams)
    
    result = subprocess.run(cmd, capture_output=True, text=True, check=True, encoding="utf-8")
    return json.loads(result.stdout)

def get_english_audio_indices(audio_streams):
    """Return indices of English or undetermined audio streams."""
    return [
        str(s["index"]) for s in audio_streams.get("streams", [])
        if s.get("tags", {}).get("language", "und") in ["eng", "und"]
    ]

def get_video_codec(video_streams):
    """Return codec name of first video stream."""
    for s in video_streams.get("streams", []):
        if s.get("codec_type") == "video":
            return s.get("codec_name", "").lower()
    return None

def get_subtitle_streams(subtitle_streams):
    """Return subtitle streams (only English or undetermined, and supported codecs)."""
    valid_codecs = {"subrip", "ass", "ssa", "mov_text"}
    return [
        {
            "index": str(s["index"]),
            "codec": s.get("codec_name", "unknown"),
            "language": s.get("tags", {}).get("language", "und"),
            "title": s.get("tags", {}).get("title", "").strip()
        }
        for s in subtitle_streams.get("streams", [])
        if s.get("codec_name") in valid_codecs and s.get("tags", {}).get("language", "und") in ["eng", "und"]
    ]

def build_ffmpeg_cmd(input_file, temp_file, mode, video_codec, audio_indices, subtitle_streams):
    """Construct ffmpeg command based on mode and available streams."""
    if mode == "encode":
        cmd = [
            "ffmpeg", "-i", input_file, "-y",
            "-c:v", "libx265", "-x265-params", "log-level=0", "-preset", "fast", "-crf", "23",
            "-c:a", "aac", "-b:a", "192k", "-channel_layout", "5.1",
            "-map", "0:v:0", "-map_metadata", "-1",
            "-tag:v", "hvc1", "-movflags", "+faststart", "-loglevel", "quiet"
        ]
    else:  # remux
        cmd = [
            "ffmpeg", "-i", input_file, "-y",
            "-c:v", "copy", "-c:a", "copy", "-map", "0:v:0", "-map_metadata", "-1",
            "-movflags", "+faststart", "-loglevel", "quiet"
        ]
        if video_codec == "hevc":
            cmd.extend(["-tag:v", "hvc1"])

    # Map English audio streams
    if audio_indices:
        for idx in audio_indices:
            cmd.extend(["-map", f"0:{idx}"])
            cmd.extend(["-metadata:s:a:0", "language=eng"])

    # Map first valid subtitle stream
    if subtitle_streams:
        sub = subtitle_streams[0]
        cmd.extend(["-map", f"0:{sub['index']}", "-c:s", "mov_text", "-metadata:s:s:0", f"language={sub['language']}"])
    cmd.append(temp_file)
    return cmd

def convert_to_mp4(input_file, temp_file, mode):
    """Main function to convert/remux to MP4."""
    try:
        audio_streams = probe_streams(input_file, "a")
        video_streams = probe_streams(input_file)
        subtitle_streams = probe_streams(input_file, "s")

        audio_indices = get_english_audio_indices(audio_streams)
        video_codec = get_video_codec(video_streams)
        valid_subtitles = get_subtitle_streams(subtitle_streams)

        if not audio_indices:
            print(f"{SYMBOL_ERROR} No English audio found. Skipping.")
            return False

        if mode == "remux" and video_codec == "av1":
            print(f"{SYMBOL_ERROR} AV1 codec detected. Please use encode mode.")
            return False

        cmd = build_ffmpeg_cmd(input_file, temp_file, mode, video_codec, audio_indices, valid_subtitles)
        print(f"{SYMBOL_INFO} Running in {mode} mode.")
        stop_event = threading.Event()
        animation_thread = threading.Thread(target=hourglass_animation, args=(stop_event, input_file, temp_file))
        animation_thread.start()
        start_time = time.time()
        subprocess.run(cmd, check=True)
        end_time = time.time()
        stop_event.set()
        animation_thread.join()
        print(f"{SYMBOL_SUCCESS} Done processing.")
        show_time(end_time - start_time)
        return True

    except subprocess.CalledProcessError as e:
        print(f"{SYMBOL_ERROR} FFmpeg error: {e}")
        return False
    except Exception as e:
        print(f"{SYMBOL_ERROR} Unexpected error: {e}")
        return False

def process_folder(input_path, output_path, first_run, create_subfolders):
    # Config
    words_to_ignore = ["sample", "SAMPLE", "Sample", ".DS_Store"]
    video_formats = [".mkv", ".mp4", ".avi"]
    global totalRunTime

    # Check folders
    if not os.path.isdir(input_path):
        sys.exit(f"{SYMBOL_ERROR} Input Directory Does Not Exist! {input_path}")

    if not os.path.isdir(output_path):
        sys.exit(f"{SYMBOL_ERROR} Output Directory Does Not Exist! {output_path}")

    print(
        f"Input Directory    : {input_path}\n"
        f"Output Directory   : {output_path}\n"
        f"Mode               : {first_run}\n"
        f"Create Subfolders  : {create_subfolders}\n"
        f"Sleeping 5 seconds...."
    )
    # sleep(5)

    if OS_name == "Darwin":
        print("WIP! macOS process function not done yet.")
        # check_if_process_running("ffmpeg")
    else:
        check_if_process_running("ffmpeg.exe")

    # Filter files to process
    files = [
        f for f in natsorted(os.listdir(input_path))
        if any(f.endswith(ext) for ext in video_formats) and not any(w in f for w in words_to_ignore)
    ]
    total_files = len(files)

    for idx, file in enumerate(files, 1):
        input_file_path = os.path.join(input_path, file)
        output_folder_name = os.path.splitext(file)[0]
        output_file_name = output_folder_name + ".mp4"

        if create_subfolders:
            output_file_dir = os.path.join(output_path, output_folder_name)
            output_file_path = os.path.join(output_file_dir, output_file_name)
        else:
            output_file_path = os.path.join(output_path, output_file_name)

        with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as temp_file:
            temp_output_file = temp_file.name

        print(f"{SYMBOL_INFO}{SYMBOL_INFO} File {idx}/{total_files}")
        print(f"{SYMBOL_INFO} Processing: {file}")

        try:
            if convert_to_mp4(input_file_path, temp_output_file, first_run):
                # Video process done. Move files to new location.
                if create_subfolders:
                    os.makedirs(output_file_dir, exist_ok=True)

                input_file_size = round(os.path.getsize(input_file_path) / (1024 * 1024))
                process_file_size = round(os.path.getsize(temp_output_file) / (1024 * 1024))

                shutil.move(temp_output_file, output_file_path)
                print(f"{SYMBOL_INFO} Moved encoded file. Old Size: {input_file_size}MB New Size: {process_file_size}MB")

                # Delete original file.
                os.remove(input_file_path)
            else:
                print(f"{SYMBOL_ERROR} Error processing this video. Moving on...")

        except Exception as e:
            print(f"{SYMBOL_ERROR} Unexpected error: {e}")
            # Optionally remove temp file if something went wrong
            try:
                os.remove(temp_output_file)
            except Exception:
                pass
            continue

        if totalRunTime < 3600:
            print(f"{SYMBOL_FINAL} Done! Total runtime: {round(totalRunTime / 60, 1)} minutes")
        else:
            print(f"{SYMBOL_FINAL} Done! Total runtime: {round(totalRunTime / 3600, 2)} hours")

if __name__ == '__main__':
    if len(sys.argv) < 5:
        print("Usage: python script.py <inputPath> <outputPath> <encode|remux> <True|False>")
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]
    first_run = sys.argv[3].lower()
    create_subfolders_arg = sys.argv[4].lower()

    if first_run not in {"encode", "remux"}:
        print("Error: <encode|remux> must be 'encode' or 'remux'.")
        sys.exit(1)

    if create_subfolders_arg in {"true", "t", "yes", "y", "1"}:
        create_subfolders = True
    elif create_subfolders_arg in {"false", "f", "no", "n", "0"}:
        create_subfolders = False
    else:
        print("Error: <True|False> must be a recognizable boolean value.")
        sys.exit(1)

    process_folder(
        input_path=input_path,
        output_path=output_path,
        first_run=first_run,
        create_subfolders=create_subfolders
    )

"""
# Upload data to DB
if firstRun == "encode":
    try:
        apiURL = "http://georgebabichev.com/plex.php"
        data = {'fileName': output_file_name,
                'originalSize': input_file_size,
                'newSize': process_file_size,
                'runtime': round(totalRunTime,2)
               }
        requests.post(apiURL,data=data,verify=False)
        print(f"{SYMBOL_SUCCESS}Uploaded data to Plex API.")
        except Exception as e:
            print(f"{SYMBOL_ERROR}Error uploading data to Plex API. {e}")
        print("") # new line
"""