#!/usr/bin/env bats
#
# The balance proxy module: which bots want it, how a bot is rewired, the unit.

setup() {
    load helper
    load_libs
    silence_logs
    DRY_RUN=true
    SCRIPT_DIR=$REPO_ROOT
    config_defaults
    SERVICE_NAME=agent-gw SERVICE_USER=svc SERVICE_GROUP=svc
    BOTS="secretary news" BOT_PREFIX=X TUNNEL_ZONE=example.com
}

@test "the provider follows the bot's model: deepseek, moonshot, nothing else" {
    BOT_SECRETARY_LLM_PROVIDER=deepseek BOT_SECRETARY_LLM_MODEL=m
    [ "$(apiproxy_provider_for secretary)" = deepseek ]
    BOT_SECRETARY_LLM_PROVIDER=custom BOT_SECRETARY_LLM_BASE_URL=https://api.moonshot.ai/v1
    [ "$(apiproxy_provider_for secretary)" = moonshot ]
    BOT_SECRETARY_LLM_PROVIDER=custom BOT_SECRETARY_LLM_BASE_URL=https://api.example.com/v1
    ! apiproxy_provider_for secretary
    [ "$(apiproxy_port deepseek)" = 8790 ]; [ "$(apiproxy_port moonshot)" = 8791 ]
}

@test "a balance footer needs an own model on a known provider" {
    BOT_SECRETARY_LLM_BALANCE=true
    _invalid=(); _check_balance secretary; [ "${#_invalid[@]}" -eq 1 ]     # no model
    BOT_SECRETARY_LLM_MODEL=m BOT_SECRETARY_LLM_PROVIDER=custom BOT_SECRETARY_LLM_BASE_URL=https://api.example.com/v1
    _invalid=(); _check_balance secretary; [ "${#_invalid[@]}" -eq 1 ]     # unknown provider
    BOT_SECRETARY_LLM_PROVIDER=deepseek BOT_SECRETARY_LLM_BASE_URL=""
    _invalid=(); _check_balance secretary; [ "${#_invalid[@]}" -eq 0 ]
    _invalid=(); _check_balance news; [ "${#_invalid[@]}" -eq 0 ]           # not asked for
}

@test "with a balance footer the bot's endpoint is the loopback proxy, the key stays the provider's" {
    LLM_ENDPOINT_COUNT=1 LLM_STRATEGY=single LLM_ENDPOINT_1_PROVIDER=custom LLM_ENDPOINT_1_NAME=bridge
    LLM_ENDPOINT_1_BASE_URL=http://127.0.0.1:8787/v1 LLM_ENDPOINT_1_MODEL=gemini LLM_ENDPOINT_1_TOKEN_VAR=""
    BOT_SECRETARY_LLM_PROVIDER=deepseek BOT_SECRETARY_LLM_MODEL=deepseek-chat BOT_SECRETARY_LLM_TOKEN_VAR=DEEPSEEK_API_KEY BOT_SECRETARY_LLM_BALANCE=true
    bot_llm_apply secretary
    [ "$LLM_ENDPOINT_1_PROVIDER" = custom ]; [ "$LLM_ENDPOINT_1_NAME" = deepseek-balance ]
    [ "$LLM_ENDPOINT_1_BASE_URL" = http://127.0.0.1:8790/v1 ]; [ "$LLM_ENDPOINT_1_TOKEN_VAR" = DEEPSEEK_API_KEY ]
    bot_llm_restore
    [ "$LLM_ENDPOINT_1_PROVIDER" = custom ]; [ "$LLM_ENDPOINT_1_NAME" = bridge ]
    [ "$(apiproxy_providers | tr '\n' ' ')" = "deepseek " ]
}

@test "the unit runs the proxy for its provider on its port, as the service account" {
    out=$(apiproxy_unit_text deepseek)
    [[ $out == *'--provider deepseek'* && $out == *'--port 8790'* && $out == *'User=svc'* && $out == *'balance_proxy.py'* ]]
    [ "$(apiproxy_unit_name moonshot)" = agent-gw-balance-moonshot ]
}
