# claude-local: run Claude Code against a local Qwen3.8-27B served by Rapid-MLX.
#
# Install:  ln -sf (pwd)/claude-local.fish ~/.config/fish/functions/claude-local.fish
# Usage:    claude-local [claude args...]   start server if needed, launch Claude Code
#           claude-local stop               stop the server, free ~20 GB RAM
#           claude-local status             health + loaded model
#           claude-local logs               tail the server log

function claude-local --description 'Claude Code on a local Qwen3.8-27B (Rapid-MLX, MTP on)'
    # --- profile ---------------------------------------------------------
    set -l model qwen3.8-27b-4bit
    set -l port 8000
    set -l effort low
    set -l base_url http://127.0.0.1:$port
    set -l log_dir ~/.cache/claude-local
    set -l log_file $log_dir/server.log
    set -l pid_file $log_dir/server.pid
    set -l repo_dir (path dirname (path resolve (status filename)))
    set -l settings_file $repo_dir/settings.local-model.json

    # Rapid-MLX serve flags. MTP speculative decoding and the qwen3 parsers
    # are auto-selected for this exact alias; no flag needed.
    set -l serve_flags \
        --port $port \
        --pin-system-prompt \
        --relocate-mid-conversation-system \
        --hybrid-cache-entries 4

    mkdir -p $log_dir

    switch "$argv[1]"
        case stop
            if test -f $pid_file
                set -l pid (cat $pid_file)
                if kill $pid 2>/dev/null
                    echo "stopped rapid-mlx (pid $pid)"
                else
                    echo "no running server for pid $pid"
                end
                rm -f $pid_file
            else
                pkill -f "rapid-mlx serve $model" && echo "stopped rapid-mlx"; or echo "server not running"
            end
            return 0

        case status
            if curl -sf $base_url/health >/dev/null
                echo "server: up on $base_url"
                curl -sf $base_url/v1/models | string match -r '"id":\s*"[^"]+"' | string replace -r '"id":\s*' 'model: '
            else
                echo "server: down"
                return 1
            end
            return 0

        case logs
            tail -f $log_file
            return 0

        case help --help -h
            echo "claude-local [claude args...] | stop | status | logs"
            return 0
    end

    # --- preflight -------------------------------------------------------
    if not command -q rapid-mlx
        echo "rapid-mlx not found. Install: brew install rapid-mlx" >&2
        return 1
    end
    if not command -q claude
        echo "claude not found. Install: npm install -g @anthropic-ai/claude-code" >&2
        return 1
    end
    if not test -f $settings_file
        echo "missing $settings_file" >&2
        return 1
    end

    # --- start server if down -------------------------------------------
    if not curl -sf $base_url/health >/dev/null
        echo "starting rapid-mlx serve $model (log: $log_file)"
        nohup rapid-mlx serve $model $serve_flags >$log_file 2>&1 &
        echo $last_pid >$pid_file
        disown

        # First run downloads ~20 GB; run `rapid-mlx pull qwen3.8-27b-4bit` first.
        set -l waited 0
        set -l limit 600
        while not curl -sf $base_url/health >/dev/null
            if not kill -0 (cat $pid_file) 2>/dev/null
                echo "server exited. last lines of $log_file:" >&2
                tail -n 20 $log_file >&2
                return 1
            end
            if test $waited -ge $limit
                echo "server not healthy after $limit s. See $log_file" >&2
                return 1
            end
            sleep 2
            set waited (math $waited + 2)
        end
        echo "server ready after $waited s"
    end

    # --- launch Claude Code ---------------------------------------------
    # Env vars are scoped to this invocation only; the normal `claude` is untouched.
    env \
        ANTHROPIC_BASE_URL=$base_url \
        ANTHROPIC_API_KEY=local \
        ANTHROPIC_MODEL=$model \
        ANTHROPIC_DEFAULT_OPUS_MODEL=$model \
        ANTHROPIC_DEFAULT_SONNET_MODEL=$model \
        ANTHROPIC_DEFAULT_HAIKU_MODEL=$model \
        ANTHROPIC_DEFAULT_FABLE_MODEL=$model \
        CLAUDE_CODE_SUBAGENT_MODEL=$model \
        CLAUDE_CODE_DISABLE_1M_CONTEXT=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        claude \
        --settings $settings_file \
        --model $model \
        --effort $effort \
        --disallowedTools Agent Workflow \
        $argv
end
