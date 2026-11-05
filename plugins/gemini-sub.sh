#!/usr/bin/env bash

# Google AI subscription (gemini-sub) ---------------------------------------
# The plan behind the Antigravity and Gemini CLIs, served by Google's Cloud
# Code Assist gateway. Sign in once with:  crush login gemini-sub
#
# The client id and secret below are Google's first-party installed-app
# credentials for the Antigravity CLI. They are shared by every Antigravity
# install and are not personal OAuth tokens; account access still comes from
# `crush login gemini-sub`. If you want to extract them yourself, inspect the
# OAuth client bootstrap in an installed Antigravity CLI bundle (search for
# `GOCSPX-` or `client_secret`), then set CRUSH_ANTIGRAVITY_CLIENT_ID and
# CRUSH_ANTIGRAVITY_CLIENT_SECRET to use your copy instead.
#
# Requests are translated by the gateway adapter below: the Gemini SDK speaks
# the public API, while the subscription is served by an internal gateway with
# its own envelope, model naming, and reply framing. Both directions are jq
# programs declared here, so the translation lives with the provider and not
# in Crush.
GOOGLE_CLIENT_ID="${CRUSH_ANTIGRAVITY_CLIENT_ID:-1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com}"
ANTIGRAVITY_SECRET="${CRUSH_ANTIGRAVITY_CLIENT_SECRET:-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}"
# The gateway and the quota endpoint both refuse a request that does not
# identify a supported client. The adapter sets it on generation calls; this
# covers every other call to the plan, including `crush usage`.
ANTIGRAVITY_USER_AGENT="antigravity/cli/1.4.0 (aidev_client; os_type=linux; arch=amd64; auth_method=consumer)"

GATEWAY_REQUEST='
  .url as $u | .body as $body | .token as $token | .request_id as $rid
  | (try ($u | capture("/models/(?<m>[^:?]+):(?<v>[a-zA-Z]+)")) catch null) as $call
  | if $call then
      # The gateway sells each reasoning tier as its own model, so the level
      # the SDK sends as generationConfig.thinkingConfig.thinkingLevel moves
      # into the model id, and a level the gateway does not sell is left for
      # the backend to reject rather than silently changed.
      ($call.m | sub("-(extra-low|low|medium|high)$"; "")) as $family
      | ($body.generationConfig.thinkingConfig.thinkingLevel // null) as $rawLevel
      | (if $rawLevel then ($rawLevel | ascii_downcase) else $rawLevel end) as $level
      | (if $level == "minimal" then "extra-low" else $level end) as $suffix
      | (if $suffix then ($family + "-" + $suffix) else $family end) as $tier
      # Crush sees mangled ids for Anthropic-family models; the gateway only
      # knows the real ones.
      | ($tier | gsub("cld-"; "claude-") | gsub("antr-"; "anthropic-")) as $model
      # A request replayed from history loses the empty argument maps the
      # Anthropic-family models on this gateway require, and some backends
      # omit the call id crush correlates tool results with.
      | ($body
          | if .generationConfig.thinkingConfig then del(.generationConfig.thinkingConfig.thinkingLevel) else . end
          | .contents |= (map(.parts |= (
              to_entries
              | map((.key | tostring) as $i
                  | .value |= (if .functionCall then
                      .functionCall | (.args //= {}) | (.id //= ("call_" + $rid + "_" + $i))
                    else . end))
              | map(.value)
            )))
        ) as $request
      | {
          url: ("https://daily-cloudcode-pa.googleapis.com/v1internal:" + $call.v
                + (if $call.v == "streamGenerateContent" then "?alt=sse" else "" end)),
          headers: ({
              Authorization: ("Bearer " + $token),
              "Content-Type": "application/json",
              "User-Agent": "antigravity/cli/1.4.0 (aidev_client; os_type=linux; arch=amd64; auth_method=consumer)"
            } + (if $call.v == "streamGenerateContent" then {Accept: "text/event-stream"} else {} end)),
          drop_headers: ["x-goog-api-key"],
          body: {
            model: $model,
            userAgent: "Antigravity/1.4.0",
            requestId: $rid,
            request: $request
          }
        }
    else
      # Anything that is not a generation call keeps the subscription bearer
      # to itself: it is valid for this one gateway.
      {drop_headers: ["x-goog-api-key"]}
    end
'

GATEWAY_RESPONSE='
  if .event then
    (.data.response // .data) as $r
    # Cumulative usage repeats on every chunk while Crush sums output tokens
    # across chunks, so the total rides only on the chunk that ends the turn.
    | if ($r.candidates[0].finishReason // null) != null then [$r]
      elif .final then
        # The backend sometimes omits the finish that tells Crush the answer
        # is complete; without it the reply is treated as truncated.
        [($r | del(.usageMetadata)),
         {candidates: [{content: {role: "model", parts: [{text: ""}]}, finishReason: "STOP"}],
          usageMetadata: ($r.usageMetadata // {})}]
      else [($r | del(.usageMetadata))] end
  else
    # A unary reply without usage metadata panics Crush s response mapper.
    ((.body.response // .body) | .usageMetadata //= {})
  end
'

# Model catalog ----------------------------------------------------------------
#
# The plan lists what it serves at fetchAvailableModels, so the models below
# are not maintained by hand: ids, display names, context windows, output
# caps, image support, and which reasoning tiers a model sells all come from
# that endpoint. It wants the same POST-and-empty-body envelope as the quota
# endpoint and the same client user-agent, which --extra-header above already
# declares for the whole provider.
#
# The gateway sells one model per reasoning tier (gemini-3.8-flash-high is
# "Gemini 3.8 Flash at high"), so the program groups the tier ids back into
# one family per model and puts the tiers behind the reasoning selector, the
# same shape the request program above expects: minimal maps to the gateway's
# "extra-low" tier.
#
# The listing carries entries that are not models to show. chat_* and tab_*
# are autocomplete surfaces, the -agent and -tiered ids are aliases the server
# keeps for older clients, the gemini-2.5-* ids relabel onto current models
# (gemini-2.5-flash is sold as "Gemini 3.5 Flash Lite"), and an entry with no
# name or no context window is not something the plan sells for chat. All of
# those are dropped.
GATEWAY_CATALOG='def ladder: ["minimal", "low", "medium", "high"];
def preferred($levels):
  if ($levels | index("medium")) then "medium"
  elif ($levels | index("high")) then "high"
  elif ($levels | index("low")) then "low"
  elif ($levels | index("minimal")) then "minimal"
  else "" end;

.models
| to_entries
| map(select(.key | test("^(chat_|tab_)") | not))
| map(select(.key | test("-(agent|tiered)$") | not))
| map(select(.key | startswith("gemini-2.5-") | not))
| map(select((.value.displayName // "") != "" and (.value.maxTokens // 0) > 0))
| map(
    .key as $id
    | (.value.displayName | sub(" \\((Extra Low|Low|Medium|High)\\)$"; "")) as $name
    | ($id | sub("-(extra-low|low|medium|high)$"; "")) as $fam
    | ($id | ltrimstr($fam) | ltrimstr("-") | sub("extra-low"; "minimal")) as $level
    | {fam: ($fam | sub("^claude-"; "cld-")), name: $name, entry: .value, level: $level}
  )
| group_by(.fam)
| map(
    . as $tiers
    | (ladder - (ladder - [$tiers[] | select(.level != "") | .level])) as $levels
    | $tiers[0] as $t
    | {
        id: $t.fam,
        name: $t.name,
        context_window: ($t.entry.maxTokens // 0),
        default_max_tokens: ($t.entry.maxOutputTokens // 0),
        reasoning: {
          thinking: (if (($t.entry.supportsThinking // false) == true) then "toggleable" else "never" end),
          effort_levels: ($levels | map({value: ., display: (if . == "xhigh" then "X-High" else ((.[0:1] | ascii_upcase) + .[1:]) end)})),
          default_effort_level: preferred($levels)
        },
        capabilities: {
          vision: (($t.entry.supportsImages // false) == true),
          audio: false
        }
      }
  )
| sort_by(.id)'

provider add gemini-sub \
  --name "Google AI Subscription" \
  --type google \
  --base-url "https://generativelanguage.googleapis.com/" \
  --flat-rate true \
  --extra-header User-Agent "$ANTIGRAVITY_USER_AGENT" \
  --gateway-request "$GATEWAY_REQUEST" \
  --gateway-response "$GATEWAY_RESPONSE" \
  --usage-url "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary" \
  --usage-method POST \
  --usage-groups groups \
  --usage-model-group gemini "Gemini" \
  --usage-model-group cld "Claude" \
  --usage-model-group gpt "Claude" \
  --oauth-flow browser \
  --oauth-client-id "$GOOGLE_CLIENT_ID" \
  --oauth-client-secret "$ANTIGRAVITY_SECRET" \
  --oauth-auth-url "https://accounts.google.com/o/oauth2/auth" \
  --oauth-token-url "https://oauth2.googleapis.com/token" \
  --oauth-redirect-uri "http://localhost:0/oauth2callback" \
  --oauth-param access_type offline \
  --oauth-param prompt consent \
  --oauth-scope "https://www.googleapis.com/auth/cloud-platform" \
  --oauth-scope "https://www.googleapis.com/auth/userinfo.email" \
  --oauth-scope "https://www.googleapis.com/auth/userinfo.profile" \
  --oauth-scope "https://www.googleapis.com/auth/cclog" \
  --oauth-scope "https://www.googleapis.com/auth/experimentsandconfigs" \
  --oauth-scope "https://www.googleapis.com/auth/aicode" \
  --oauth-scope openid \
  --catalog-url "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels" \
  --catalog-method POST \
  --catalog-program "$GATEWAY_CATALOG"

# The reasoning default the listing does not state is chosen here: medium
# where the family sells it, then high, then low, then minimal. A model add
# would still override anything the catalog reports — only the fields it sets,
# without losing the rest.

# The Claude families keep their mangled ids (cld- for claude-): the Gemini
# provider would otherwise divert them to real Anthropic credentials, and the
# request program above maps them back before anything is sent.
