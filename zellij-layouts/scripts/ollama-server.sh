#!/usr/bin/env bash
set -euo pipefail

# Garante as variáveis aqui dentro para o servidor
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_MODELS="$HOME/.cache/ollama/models"
export OLLAMA_LLM_LIBRARY="vulkan"
export OLLAMA_IGPU_ENABLE=1
export OLLAMA_LLM_LIBRARY="vulkan"

# Garante acesso aos drivers do Arch
export LD_LIBRARY_PATH="/usr/lib:/usr/lib32:${LD_LIBRARY_PATH:-}"
export VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/intel_icd.x86_64.json:${VK_ICD_FILENAMES:-}"

echo "🧠 Starting Ollama Server with Vulkan..."
ollama serve
