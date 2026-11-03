/// Known virtual models exposed by the vLLM Semantic Router.
///
/// The app only offers these defaults when the gateway advertises the
/// vllm-sr provider; otherwise it only shows models in the gateway inventory.
const turboVirtualModelIds = <String>[
  'vllm-sr/turbo',
  'vllm-sr/free-quality',
  'vllm-sr/free-reasoning',
  'vllm-sr/free-verify',
  'vllm-sr/free-longctx',
  'vllm-sr/free-public',
];

bool isTurboModelRoute(String provider, String model) =>
    provider.trim().toLowerCase() == 'vllm-sr' ||
    model.trim().toLowerCase().startsWith('vllm-sr/');

String turboModelAlias(String model) {
  final normalized = model.trim().toLowerCase();
  return normalized.startsWith('vllm-sr/')
      ? normalized.substring('vllm-sr/'.length)
      : normalized;
}

/// Keep the router's documented virtual routes above other advertised routes.
int compareTurboModelIds(String left, String right) {
  const order = <String>[
    'turbo',
    'free-quality',
    'free-reasoning',
    'free-verify',
    'free-longctx',
    'free-public',
  ];
  final leftAlias = turboModelAlias(left);
  final rightAlias = turboModelAlias(right);
  final leftIndex = order.indexOf(leftAlias);
  final rightIndex = order.indexOf(rightAlias);
  final leftRank = leftIndex < 0 ? order.length : leftIndex;
  final rightRank = rightIndex < 0 ? order.length : rightIndex;
  if (leftRank != rightRank) return leftRank.compareTo(rightRank);
  return left.compareTo(right);
}
