# voxtype-llm-wrapper

An [Ollama](https://ollama.com) Modelfile that turns a local LLM into a
transcript editor for [voxtype](https://github.com/peteonrails/voxtype),
giving WisprFlow-style cleanup of dictated text without sending anything off
your machine.

The model takes raw speech-to-text output on stdin and returns a cleaned
version: punctuation and capitalization fixed, filler words and false starts
removed, self-corrections resolved ("Tuesday, no wait, Wednesday" becomes
"Wednesday"), and emails, messages, and lists formatted sensibly. It is
instructed to treat everything it receives as dictation, so saying "how do I
restart the server" produces `How do I restart the server?` rather than an
answer.

## Requirements

- [Ollama](https://ollama.com/download) installed and running (`ollama serve`,
  or the systemd service)
- [voxtype](https://github.com/peteonrails/voxtype) 1.0 or newer
- Roughly 5 GB of disk for the base model, and a GPU or a reasonably fast CPU.
  The default base is `qwen2.5:7b`; see [Choosing a base model](#choosing-a-base-model)
  if that is too heavy.

## Quick setup

`setup.sh` does everything in the next two sections in one go:

```sh
git clone https://github.com/xuancongwen/voxtype-llm-wrapper
cd voxtype-llm-wrapper
./setup.sh
```

It checks that Ollama is running and voxtype is 1.0 or newer, pulls the base
model, builds `voxtype-llm-wrapper`, runs a smoke test, appends a
`[output.post_process]` block to `~/.config/voxtype/config.toml` (after
backing the file up), and restarts the `voxtype` user service if one is
running.

Things it deliberately does not do:

- It never installs Ollama or voxtype. If either is missing it stops and says
  so.
- It never overwrites an existing `[output.post_process]` block. If you
  already have one, it prints it and leaves it to you.
- If voxtype is running outside systemd, it asks you to restart it yourself.

To build from a different base model without editing the Modelfile, pass the
model name as the only argument:

```sh
./setup.sh llama3.2:3b
```

The script is plain POSIX shell with no dependencies beyond `ollama`,
`voxtype`, and the usual coreutils, so it should behave the same on Arch,
Debian, Ubuntu, and Fedora. It has been tested on Arch.

If you would rather do the steps by hand, or want to understand what the
script did, read on.

## Generating the model with Ollama

1. Pull the base model:

   ```sh
   ollama pull qwen2.5:7b
   ```

2. Build the wrapper model from the Modelfile in this repo:

   ```sh
   cd voxtype-llm-wrapper
   ollama create voxtype-llm-wrapper -f Modelfile
   ```

3. Confirm it works by piping some messy dictation through it:

   ```sh
   echo "um so let's meet tuesday no wait wednesday at four" | ollama run --nowordwrap voxtype-llm-wrapper
   ```

   Expected output:

   ```
   Let's meet Wednesday at four.
   ```

Re-run `ollama create` any time you edit the Modelfile. The existing model is
replaced in place.

## Using it with voxtype

voxtype can pipe every transcription through an external command before typing
it out. Point that command at the model you just created.

Open `~/.config/voxtype/config.toml` and add (or edit) the post-processing
section under `[output]`:

```toml
[output.post_process]
command = "ollama run --nowordwrap voxtype-llm-wrapper"
timeout_ms = 30000
trim = true
fallback_on_empty = true
```

What each setting does:

| Key | Purpose |
| --- | --- |
| `command` | Shell command that receives the transcript on stdin and prints the cleaned text on stdout. |
| `timeout_ms` | How long to wait for the LLM. Raise this on slow hardware. If it times out, voxtype types the original transcript. |
| `trim` | Strip leading and trailing whitespace from the model output. |
| `fallback_on_empty` | If the model returns nothing, type the original transcript instead of nothing. |

Then restart the voxtype daemon so it picks up the change:

```sh
voxtype daemon
```

Or, if you run it as a systemd user service:

```sh
systemctl --user restart voxtype
```

Press your voxtype hotkey, dictate, and the cleaned text is typed at the
cursor. On any failure (Ollama not running, timeout, error) voxtype falls back
to the raw Whisper transcript, so enabling this never blocks dictation.

### Keeping the model warm

Ollama unloads a model after a few minutes idle, and the first request after
that pays a load cost of several seconds. To keep it resident, set a longer
keep-alive for the Ollama server, for example in the systemd override or your
shell environment:

```sh
OLLAMA_KEEP_ALIVE=24h
```

## Choosing a base model

The Modelfile starts with `FROM qwen2.5:7b`, which gives good edits while
staying fast on a mid-range GPU. To use a different base, change the `FROM`
line and rebuild:

```sh
sed -i 's/^FROM .*/FROM llama3.2:3b/' Modelfile
ollama pull llama3.2:3b
ollama create voxtype-llm-wrapper -f Modelfile
```

Smaller models are faster but more likely to answer questions instead of
editing them, or to drop content. Test with the examples in the Modelfile
before relying on a new base.

## How the Modelfile works

- `temperature 0.0` makes output deterministic, so the same dictation always
  produces the same edit.
- `num_ctx 4096` is plenty for voxtype's default 60-second recording limit.
- The `SYSTEM` prompt contains the editing rules, contextual formatting rules
  for emails, messages, and lists, and a set of input/output examples. The
  examples are the most effective lever if you want to change behaviour; add
  a new pair that shows the edit you want.

## Troubleshooting

- **Text is typed unchanged.** The post-process command failed or timed out.
  Run the `echo ... | ollama run` test above to check that Ollama is up and the
  model exists, and run `voxtype -v daemon` to see the error.
- **Nothing is typed.** Set `fallback_on_empty = true` so an empty model
  response falls back to the raw transcript.
- **The model answers instead of editing.** Try a larger base model, or add an
  example to the `SYSTEM` prompt showing the exact phrasing being preserved.
- **Long delay before text appears.** The model is being loaded on each
  request. See [Keeping the model warm](#keeping-the-model-warm).
