/// Per-kind layout for the native ephemeral-ui renderer.
///
/// One explicit entry per catalog kind (catalog-v0.1.0). When the
/// vendored catalog gains a kind, the gallery coverage test fails until the
/// kind gets an entry here, so a gap is never silent.
library;

enum EphemeralLayoutType { fields, metric, meter, route, messages }

/// How a kind's props are drawn: an optional hero (a headline number, a
/// meter, a from→to route or a message list) over the remaining props.
final class EphemeralLayout {
  /// Every prop as a labelled field, list or nested section.
  const EphemeralLayout.fields()
    : type = EphemeralLayoutType.fields,
      a = null,
      b = null,
      c = null,
      d = null;

  /// A headline number from [value], with optional unit, % delta, caption.
  const EphemeralLayout.metric(
    String value, {
    String? unit,
    String? delta,
    String? caption,
  }) : type = EphemeralLayoutType.metric,
       a = value,
       b = unit,
       c = delta,
       d = caption;

  /// A used/limit bar.
  const EphemeralLayout.meter(String used, String limit)
    : type = EphemeralLayoutType.meter,
      a = used,
      b = limit,
      c = null,
      d = null;

  /// A from → to headline.
  const EphemeralLayout.route(String from, String to)
    : type = EphemeralLayoutType.route,
      a = from,
      b = to,
      c = null,
      d = null;

  /// A list of who/text messages.
  const EphemeralLayout.messages(String list)
    : type = EphemeralLayoutType.messages,
      a = list,
      b = null,
      c = null,
      d = null;

  final EphemeralLayoutType type;
  final String? a;
  final String? b;
  final String? c;
  final String? d;

  /// Props the hero draws, left out of the field list below it.
  Set<String> get heroKeys => {?a, ?b, ?c, ?d};
}

/// Every kind this app draws natively, in catalog order.
const Map<String, EphemeralLayout> ephemeralKindLayouts = {
  // studio
  'sculpt': EphemeralLayout.fields(),
  'city': EphemeralLayout.fields(),
  'fly': EphemeralLayout.fields(),
  'fpv': EphemeralLayout.fields(),
  'light': EphemeralLayout.fields(),
  'trigger': EphemeralLayout.fields(),
  'globe': EphemeralLayout.fields(),
  'gen3d': EphemeralLayout.fields(),
  'sim': EphemeralLayout.fields(),
  // app
  'inbox': EphemeralLayout.fields(),
  'thread': EphemeralLayout.fields(),
  'approve': EphemeralLayout.fields(),
  'chat': EphemeralLayout.messages('messages'),
  'notify': EphemeralLayout.messages('items'),
  'slots': EphemeralLayout.fields(),
  'kanban': EphemeralLayout.route('moved', 'to'),
  'triage': EphemeralLayout.fields(),
  'file': EphemeralLayout.fields(),
  'graph': EphemeralLayout.fields(),
  'search': EphemeralLayout.fields(),
  'feed': EphemeralLayout.fields(),
  'frames': EphemeralLayout.fields(),
  'sign': EphemeralLayout.fields(),
  'context': EphemeralLayout.meter('used', 'limit'),
  'receipt': EphemeralLayout.metric(
    'amount',
    unit: 'currency',
    caption: 'payee',
  ),
  'metric': EphemeralLayout.metric('value', delta: 'delta', caption: 'label'),
  'track': EphemeralLayout.fields(),
  'crm': EphemeralLayout.metric('amount', caption: 'company'),
  'ride': EphemeralLayout.route('from', 'to'),
  'route': EphemeralLayout.route('from', 'to'),
  'boarding': EphemeralLayout.route('from', 'to'),
  'player': EphemeralLayout.fields(),
  'workout': EphemeralLayout.metric('distance_km'),
  'home': EphemeralLayout.metric('value', caption: 'device'),
  'merge': EphemeralLayout.route('head', 'base'),
  'ci': EphemeralLayout.fields(),
  'deploy': EphemeralLayout.route('ref', 'target'),
  'incident': EphemeralLayout.fields(),
  'migrate': EphemeralLayout.fields(),
  // studio
  'nodes': EphemeralLayout.fields(),
  'timeline': EphemeralLayout.fields(),
  'review': EphemeralLayout.fields(),
  'layers': EphemeralLayout.fields(),
  'gallery': EphemeralLayout.fields(),
  'cad': EphemeralLayout.fields(),
  'board': EphemeralLayout.fields(),
  'daw': EphemeralLayout.fields(),
  'flash': EphemeralLayout.fields(),
  'stage': EphemeralLayout.fields(),
  'anatomy': EphemeralLayout.fields(),
  // agent
  'cua-action': EphemeralLayout.fields(),
  'work-dock': EphemeralLayout.fields(),
  // studio
  'screen': EphemeralLayout.fields(),
  'sandbox': EphemeralLayout.fields(),
  'twin': EphemeralLayout.fields(),
  'health': EphemeralLayout.fields(),
  // fleet
  'fleet-hosts': EphemeralLayout.fields(),
  'fleet-portfolio': EphemeralLayout.fields(),
  'fleet-factory': EphemeralLayout.fields(),
  // agent
  'gev-contacts': EphemeralLayout.fields(),
  // intent
  'intent-declare': EphemeralLayout.fields(),
  'intent-contract': EphemeralLayout.fields(),
  'intent-work': EphemeralLayout.fields(),
  'intent-proof': EphemeralLayout.fields(),
  'intel-decisions': EphemeralLayout.fields(),
  'intel-value': EphemeralLayout.fields(),
  'intel-context': EphemeralLayout.fields(),
  'intel-health': EphemeralLayout.fields(),
  // intel
  'intel-suite': EphemeralLayout.fields(),
  // ops
  'ops-burn': EphemeralLayout.fields(),
  'ops-alive': EphemeralLayout.fields(),
  'ops-incidents': EphemeralLayout.fields(),
  'ops-fleet': EphemeralLayout.fields(),
  'ops-slow': EphemeralLayout.fields(),
  'ops-models': EphemeralLayout.fields(),
  'ops-tokens': EphemeralLayout.fields(),
  'ops-context': EphemeralLayout.fields(),
  'ops-tools': EphemeralLayout.fields(),
  'ops-routing': EphemeralLayout.fields(),
  'ops-sources': EphemeralLayout.fields(),
  // studio
  'plugin': EphemeralLayout.fields(),
  // trace
  'trace': EphemeralLayout.fields(),
  'trace-span': EphemeralLayout.fields(),
  'trace-summary': EphemeralLayout.fields(),
  'trace-usage': EphemeralLayout.fields(),
  'trace-tools': EphemeralLayout.fields(),
  'trace-errors': EphemeralLayout.fields(),
  'trace-compare': EphemeralLayout.route('a', 'b'),
  'trace-frustration': EphemeralLayout.fields(),
};
