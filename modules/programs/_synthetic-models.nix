# Synthetic's always-on models, from /openai/v1/models with the key; pi maps
# this to its own schema.
# The ids are pinned rather than using the `syn:` routing aliases, so a
# model Synthetic rotates out has to be replaced here.
#
# `efforts` is the endpoint's own reasoning_parameters.efforts for the model:
# pi turns it into thinkingLevelMap (a level it lacks is null = not offered).
# "none" means thinking can be turned off.
#
# `cost` is Synthetic's subscription discounted rate (synthetic.new/pricing/models),
# not the usage-based price /models reports: that is the rate the weekly credit
# meter is drawn down at, so pi's session cost tracks credit burn. Per Mtok.
{
  "hf:deepseek-ai/DeepSeek-V4.1-Flash" = {
    name = "DeepSeek V4.1 Flash";
    ctx = 524288;
    maxOut = 65536;
    input = ["text" "image"];
    efforts = ["none" "low" "high" "xhigh" "max"];
    cost = {
      input = 0.06;
      cached = 0.003;
      output = 0.30;
    };
  };
  "hf:deepseek-ai/DeepSeek-V4.1-Flash-1017" = {
    name = "DeepSeek V4.1 Flash 1017";
    ctx = 524288;
    maxOut = 65536;
    input = ["text" "image"];
    efforts = ["none" "low" "high" "xhigh" "max"];
    cost = {
      input = 0.06;
      cached = 0.003;
      output = 0.30;
    };
  };
  "hf:moonshotai/Kimi-K3" = {
    name = "Kimi K3";
    ctx = 524288;
    maxOut = 65536;
    input = ["text" "image"];
    efforts = ["low" "high" "max"];
    cost = {
      input = 1.5;
      cached = 0.23;
      output = 7.5;
    };
  };
  "hf:zai-org/GLM-5.3-Flash" = {
    name = "GLM-5.3-Flash";
    ctx = 524288;
    maxOut = 65536;
    input = ["text" "image"];
    efforts = ["low" "high" "max"];
    cost = {
      input = 0.10;
      cached = 0.02;
      output = 0.25;
    };
  };
  "hf:zai-org/GLM-4.7-Flash" = {
    name = "GLM-4.7-Flash";
    ctx = 196608;
    maxOut = 65536;
    input = ["text"];
    efforts = ["none" "low" "medium" "high"];
    cost = {
      input = 0.01;
      cached = 0.003;
      output = 0.05;
    };
  };
  "hf:Qwen/Qwen3.8-27B" = {
    name = "Qwen3.8 27B";
    ctx = 262144;
    maxOut = 65536;
    input = ["text" "image"];
    efforts = ["low" "medium" "xhigh"];
    cost = {
      input = 0.23;
      cached = 0.05;
      output = 1.1;
    };
  };
  "hf:nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4" = {
    name = "Nemotron 3 Super 120B";
    ctx = 262144;
    maxOut = 65536;
    input = ["text"];
    efforts = ["none" "low" "medium" "high"];
    cost = {
      input = 0.10;
      cached = 0.02;
      output = 0.40;
    };
  };
  "hf:openai/gpt-oss-120b" = {
    name = "gpt-oss-120b";
    ctx = 131072;
    maxOut = 65536;
    input = ["text"];
    efforts = ["none" "low" "medium" "high"];
    cost = {
      input = 0.01;
      cached = 0.003;
      output = 0.05;
    };
  };
}
