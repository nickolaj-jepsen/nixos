# The TensorX models pi sessions actually pick, by hand for data-sensitive work.
# pi has no discovery for hosted OpenAI-compatible endpoints (only llama.cpp's
# router), so limits, capabilities and prices from `/v1/model/info` are static
# here — update them when TensorX changes them, since pi charges the session's
# cost against `cost`.
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
]
