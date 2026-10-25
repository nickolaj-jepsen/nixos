# Static copy of TensorX's /v1/model/info: pi can't discover hosted endpoints.
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
