# TensorX's curated chat models. pi has no discovery for hosted OpenAI-compatible
# endpoints (only llama.cpp's router), so limits, capabilities and prices from
# `/v1/model/info` are static here — update them when TensorX changes them, since
# pi charges the session's cost against `cost`.
#
# Per-model quirks live next to their model: `compat` for wire differences the
# endpoint can't declare, `thinkingLevelMap` for which levels it actually accepts
# (null = rejected, missing = pi's default).
[
  {
    id = "qwen/qwen3.8-flash-next";
    name = "Qwen3.8 Flash Next";
    reasoning = true;
    input = ["text" "image"];
    contextWindow = 262144;
    maxTokens = 64000;
    cost = {
      input = 0.2;
      output = 0.5;
      cacheRead = 0.05;
      cacheWrite = 0;
    };
    promptCache.short = 300;
    # Its own levels: `high` is a 400, and thinking can't be turned off.
    thinkingLevelMap = {
      off = null;
      minimal = null;
      low = "low";
      medium = "medium";
      high = null;
      xhigh = "xhigh";
      max = null;
    };
  }
  {
    id = "z-ai/glm-5.3";
    name = "GLM 5.3";
    reasoning = true;
    input = ["text"];
    contextWindow = 1048576;
    maxTokens = 64000;
    cost = {
      input = 1.75;
      output = 4.5;
      cacheRead = 0.44;
      cacheWrite = 0;
    };
    promptCache.short = 300;
    # Always reasons; 5.3 dropped `thinking.type: "disabled"`.
    thinkingLevelMap = {
      off = null;
      minimal = null;
      low = "low";
      medium = null;
      high = "high";
      xhigh = null;
      max = "max";
    };
  }
  {
    id = "moonshotai/kimi-k3";
    name = "Kimi K3";
    reasoning = true;
    input = ["text" "image"];
    contextWindow = 1048576;
    maxTokens = 64000;
    cost = {
      input = 3;
      output = 15;
      cacheRead = 0.75;
      cacheWrite = 0;
    };
    promptCache.short = 300;
    # Always reasons, like GLM 5.x.
    thinkingLevelMap = {
      off = null;
      minimal = null;
      low = "low";
      medium = null;
      high = "high";
      xhigh = null;
      max = "max";
    };
  }
  {
    id = "deepseek/deepseek-v4.1-flash";
    name = "DeepSeek V4.1 Flash";
    reasoning = true;
    input = ["text" "image"];
    contextWindow = 1048576;
    maxTokens = 64000;
    cost = {
      input = 0.5;
      output = 1.5;
      cacheRead = 0.13;
      cacheWrite = 0;
    };
    promptCache.short = 300;
    # `off` stays unset, not null, or it's dropped from the picker.
    thinkingLevelMap = {
      minimal = null;
      low = null;
      medium = null;
      high = "high";
      max = "max";
    };
    compat = {
      # DeepSeek rejects replayed turns missing reasoning_content.
      requiresReasoningContentOnAssistantMessages = true;
      thinkingFormat = "deepseek";
      supportsLongCacheRetention = true;
    };
  }
]
