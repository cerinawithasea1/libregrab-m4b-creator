#!/bin/bash

# Basic error handling
set -e

# Get the directory of the script
DIR=$(dirname $(realpath $0))

# Check ffmpeg dependency
if ! command -v "ffmpeg" &> /dev/null; then
    echo "Error: ffmpeg is required but not found."
    echo "Please install ffmpeg before running this script."
    exit 1
fi

# Display usage instructions if no directory provided
# Default output directory
OUTPUT_DIR="~/Downloads"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            if [[ -n "$2" ]]; then
                OUTPUT_DIR="$2"
                shift 2
            else
                echo "Error: --output-dir requires a directory path"
                exit 1
            fi
            ;;
        *)
            INPUT_DIRS+=("$1")
            shift
            ;;
    esac
done

# Display usage instructions if no input directories provided
if [ ${#INPUT_DIRS[@]} -eq 0 ]; then
    echo "Usage: $0 [--output-dir <output_directory>] <directory_path1> [directory_path2 ...]"
    echo "Example: $0 --output-dir ~/MyAudiobooks ~/Downloads/MyAudiobook1 ~/Downloads/MyAudiobook2"
    echo "Notes:"
    echo "- Each directory should contain MP3 files"
    echo "- Cover art (cover.jpg/png) and metadata.json are optional"
    echo "- Default output directory: /Users/cerinawithasea/totag"
    exit 1
fi

# Verify output directory exists and is writable
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR" || {
        echo "Error: Failed to create output directory: $OUTPUT_DIR"
        exit 1
    }
fi

if [ ! -w "$OUTPUT_DIR" ]; then
    echo "Error: Output directory is not writable: $OUTPUT_DIR"
    exit 1
fi

process_directory() {
    local dir="$1"
    # Get absolute path and book title from directory name
    WORKDIR=$(cd "$dir" && pwd)
    BOOK_TITLE=$(basename "$WORKDIR")
    AUTHOR="Unknown Author"  # Can be updated from metadata if available
    YEAR="2024"
    
    echo "Processing audiobook: $BOOK_TITLE"
    
    # Change to working directory
    cd "$WORKDIR"
    

# Create list of audio files
echo "Creating list of audio files..."
find . -maxdepth 1 -name "*.mp3" -type f | sort | sed "s/^\\.\\/*/file '/;s/$/\'/" > audiofiles.txt

if [ -f audiofiles.txt ]; then
    echo "Audio files list created:"
    cat audiofiles.txt
else
    echo "Error: Failed to create audiofiles.txt"
    exit 1
fi

# Get the bitrate of the first file
FIRST_FILE=$(head -n 1 audiofiles.txt | sed "s/file '//;s/'//")
BITRATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$FIRST_FILE")

# If bitrate detection fails, provide a warning and default to input file's bitrate
if [ -z "$BITRATE" ] || [ "$BITRATE" = "N/A" ]; then
    echo "Warning: Could not detect input bitrate, will maintain input file's bitrate"
    BITRATE_OPT=""
else
    BITRATE_OPT="-b:a ${BITRATE}"
fi

# Check if metadata.json exists
if [ -f "metadata/metadata.json" ]; then
    echo "Found metadata.json, using it for chapter information..."
    python3 "$DIR/convert_chapters.py" metadata/metadata.json
    python3 "$DIR/convert_to_ffmpeg_chapters.py" chapters.txt
else
    echo "No metadata.json found, using MP3 filenames for chapters..."
    # Create chapters metadata from MP3 files
    echo "Generating chapter metadata..."
    echo ";FFMETADATA1" > ffmpeg_chapters.txt

    current_time=0
    while IFS= read -r line; do
        # Extract filename without path and extension
        filename=$(basename "$line" .mp3)
        filename=${filename#"file '"}
        filename=${filename%"'"}
        
        # Get duration of current file
        duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$filename")
        duration=${duration%.*} # Remove decimal places
        
        # Write chapter metadata
        echo "[CHAPTER]" >> ffmpeg_chapters.txt
        echo "TIMEBASE=1/1" >> ffmpeg_chapters.txt
        echo "START=$current_time" >> ffmpeg_chapters.txt
        next_time=$((current_time + duration))
        echo "END=$next_time" >> ffmpeg_chapters.txt
        echo "title=$filename" >> ffmpeg_chapters.txt
        
        current_time=$next_time
    done < audiofiles.txt
fi

# Convert to M4B format
# Get the bitrate of the first file
FIRST_FILE=$(head -n 1 audiofiles.txt | sed "s/file '//;s/'//")
BITRATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$FIRST_FILE")

# If bitrate detection fails, provide a warning and default to input file's bitrate
if [ -z "$BITRATE" ] || [ "$BITRATE" = "N/A" ]; then
    echo "Warning: Could not detect input bitrate, will maintain input file's bitrate"
    BITRATE_OPT=""
else
    BITRATE_OPT="-b:a ${BITRATE}"
fi

# Construct FFmpeg command
FFMPEG_CMD="ffmpeg -y -f concat -safe 0 -i audiofiles.txt -i ffmpeg_chapters.txt -map 0 -metadata album=\"$BOOK_TITLE\" -metadata artist=\"$AUTHOR\" -metadata title=\"$BOOK_TITLE\" -metadata date=\"$YEAR\" -metadata genre=\"Audiobook\" -c:a aac $BITRATE_OPT -movflags +faststart \"${BOOK_TITLE}.m4b\""

echo "Converting to M4B format..."
# Start FFmpeg in background
eval "$FFMPEG_CMD" >/dev/null 2>&1 &
ffmpeg_pid=$!

# Show spinning animation while FFmpeg runs
spin='-\|/'
i=0
while kill -0 $ffmpeg_pid 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\rConverting... %s" "${spin:$i:1}"
    sleep .1
done

# Wait for FFmpeg to finish and check its exit status
wait $ffmpeg_pid
if [ $? -eq 0 ]; then
    printf "\rConversion complete!     \n"
    echo "Output file: ${BOOK_TITLE}.m4b"
    echo "You can now test the audiobook in your preferred player."
    echo "Moving audiobook to totag directory..."
    mv "${BOOK_TITLE}.m4b" "$OUTPUT_DIR/"
    else
    printf "\rConversion failed!     \n"
    exit 1
fi

# Cleanup temporary files
echo "Cleaning up temporary files..."
rm -f audiofiles.txt ffmpeg_chapters.txt chapters.json
}

# Process each provided directory
for dir in "${INPUT_DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        echo "Warning: $dir is not a directory, skipping..."
        continue
    fi
    process_directory "$dir"
    echo "Completed processing: $dir"
    echo "----------------------------------------"
done

echo "All audiobooks processed successfully!"
