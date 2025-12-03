import 'dart:async';
import 'dart:convert';

import 'package:budget/database/platform/shared.dart' as platform;
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/defaultPreferences.dart';
import 'package:budget/struct/settings.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:telephony/telephony.dart';

class SmsHeuristicResult {
  const SmsHeuristicResult._({
    required this.shouldProcess,
    required this.normalizedSender,
    required this.normalizedBody,
    this.amount,
    this.currency,
    this.isIncome,
    this.reason,
  });

  factory SmsHeuristicResult.reject({
    required String normalizedSender,
    required String normalizedBody,
    required String reason,
  }) {
    return SmsHeuristicResult._(
      shouldProcess: false,
      normalizedSender: normalizedSender,
      normalizedBody: normalizedBody,
      reason: reason,
    );
  }

  factory SmsHeuristicResult.approve({
    required double amount,
    required String currency,
    required bool isIncome,
    required String normalizedSender,
    required String normalizedBody,
  }) {
    return SmsHeuristicResult._(
      shouldProcess: true,
      normalizedSender: normalizedSender,
      normalizedBody: normalizedBody,
      amount: amount,
      currency: currency,
      isIncome: isIncome,
    );
  }

  final bool shouldProcess;
  final String normalizedSender;
  final String normalizedBody;
  final double? amount;
  final String? currency;
  final bool? isIncome;
  final String? reason;

  double? get signedAmount =>
      amount == null || isIncome == null ? null : (isIncome! ? amount : -amount!);

  Map<String, dynamic> toContext(String originalSender) {
    final context = <String, dynamic>{
      "original_sender": originalSender,
      "normalized_sender": normalizedSender,
      "amount_detected": amount,
      "suggested_signed_amount": signedAmount,
      "currency": currency,
      "direction_hint": isIncome == null
          ? null
          : isIncome!
              ? "credit"
              : "debit",
    };
    context.removeWhere((key, value) => value == null);
    return context;
  }
}

class _AmountCandidate {
  _AmountCandidate({
    required this.value,
    required this.currency,
    required this.contextSnippet,
    required this.matchIndex,
  });

  final double value;
  final String? currency;
  final String contextSnippet;
  final int matchIndex;

  String get _normalizedSnippet => contextSnippet.toLowerCase();

  bool get isBalanceContext {
    return BankSmsHeuristics._balanceKeywords
        .any((keyword) => _normalizedSnippet.contains(keyword));
  }

  bool get hasTransactionCue {
    return BankSmsHeuristics._transactionContextKeywords
        .any((keyword) => _normalizedSnippet.contains(keyword));
  }
}

class BankSmsHeuristics {
  BankSmsHeuristics({
    required List<String> senderKeywords,
  }) : senderKeywords = senderKeywords.isEmpty
            ? List<String>.from(defaultSmsSenderKeywords)
            : senderKeywords;

  final List<String> senderKeywords;

  static const String _rupeeSymbol = '\u20b9';
  static const String _currencyTokenPattern =
      '(?:$_rupeeSymbol|rs\\.?|inr|usd|eur|gbp|aed|sar|qar|sgd|aud|cad|jpy|myr)';
  static final RegExp _amountRegex = RegExp(
    '(?:(' +
        _currencyTokenPattern +
        ')\\s*[:\\-]?\\s*)?([+-]?\\d{1,3}(?:,\\d{3})*(?:\\.\\d+)?|\\d+\\.\\d+)(?:\\s*(' +
        _currencyTokenPattern +
        '))?',
    caseSensitive: false,
  );

  static final RegExp _otpRegex = RegExp(
    r'\b(otp|one[-\s]?time\s+(?:password|code)|verification\s+code)\b',
    caseSensitive: false,
  );
  static final RegExp _reminderRegex = RegExp(
    r'\b(due\s+(?:on|by)|to\s+be\s+debited|will\s+be\s+(?:debited|credited))\b',
    caseSensitive: false,
  );

  static const List<String> _debitKeywords = [
    "debit",
    "debited",
    "spent",
    "payment of",
    "payment has been done",
    "purchase",
    "paid",
    "upi",
    "top-up",
    "top up",
    "transfer",
    "withdrawn",
    "deducted",
    "autodebit",
    "auto-debit",
  ];

  static const List<String> _creditKeywords = [
    "credit",
    "credited",
    "received",
    "deposited",
    "refunded",
    "refund",
    "income",
  ];

  static const List<String> _balanceKeywords = [
    "available balance",
    "avail bal",
    "available bal",
    "avbl",
    "avl",
    "available limit",
    "avail limit",
    "avl lmt",
    "limit",
    "lmt",
    "balance",
    "bal",
    "closing balance",
    "current balance",
  ];
  static final List<String> _transactionContextKeywords = [
    ..._debitKeywords,
    ..._creditKeywords,
    "spent",
    "payment",
    "purchase",
    "pos",
    "card",
    "at ",
    "upi",
    "transfer",
  ];

  SmsHeuristicResult evaluate(SmsMessage message) {
    final senderRaw = (message.address ?? "").trim();
    final bodyRaw = (message.body ?? "").trim();
    final normalizedSender = senderRaw.toLowerCase();
    final normalizedBody = bodyRaw.toLowerCase();

    if (bodyRaw.isEmpty) {
      return SmsHeuristicResult.reject(
        normalizedSender: normalizedSender,
        normalizedBody: normalizedBody,
        reason: "Empty SMS body",
      );
    }

    if (!_matchesSenderOrBody(normalizedSender, normalizedBody)) {
      return SmsHeuristicResult.reject(
        normalizedSender: normalizedSender,
        normalizedBody: normalizedBody,
        reason: "Sender not in whitelist",
      );
    }

    if (_otpRegex.hasMatch(normalizedBody)) {
      return SmsHeuristicResult.reject(
        normalizedSender: normalizedSender,
        normalizedBody: normalizedBody,
        reason: "OTP detected",
      );
    }

    final bool reminder = _reminderRegex.hasMatch(normalizedBody);
    final bool processedMessage = normalizedBody.contains("successfully processed") ||
        normalizedBody.contains("has been processed");

    if (reminder && processedMessage == false) {
      return SmsHeuristicResult.reject(
        normalizedSender: normalizedSender,
        normalizedBody: normalizedBody,
        reason: "Payment reminder detected",
      );
    }

    final bool creditCardPaymentAcknowledgement =
        normalizedBody.contains("credit card") &&
            normalizedBody.contains("payment") &&
            normalizedBody.contains("received");
    if (creditCardPaymentAcknowledgement) {
      return SmsHeuristicResult.reject(
        normalizedSender: normalizedSender,
        normalizedBody: normalizedBody,
        reason: "Credit card payment acknowledgement",
      );
    }

    final candidates = _extractAmountCandidates(bodyRaw);
    final filteredCandidates =
        candidates.where((candidate) => !candidate.isBalanceContext).toList();

    if (filteredCandidates.isEmpty) {
      return SmsHeuristicResult.reject(
        normalizedSender: normalizedSender,
        normalizedBody: normalizedBody,
        reason: "No transaction amount found",
      );
    }

    final candidate = _selectBestCandidate(filteredCandidates);
    if (candidate == null) {
      return SmsHeuristicResult.reject(
        normalizedSender: normalizedSender,
        normalizedBody: normalizedBody,
        reason: "Multiple amount candidates",
      );
    }
    final bool hasCreditKeyword =
        _creditKeywords.any((keyword) => normalizedBody.contains(keyword));
    final bool hasDebitKeyword =
        _debitKeywords.any((keyword) => normalizedBody.contains(keyword));
    final bool mentionsTopUp =
        normalizedBody.contains("top-up") || normalizedBody.contains("top up");
    final bool creditToBeneficiary =
        normalizedBody.contains("credited to beneficiary");

    if (!hasCreditKeyword && !hasDebitKeyword && !mentionsTopUp) {
      return SmsHeuristicResult.reject(
        normalizedSender: normalizedSender,
        normalizedBody: normalizedBody,
        reason: "Missing debit/credit keywords",
      );
    }

    bool isIncome = hasCreditKeyword && !hasDebitKeyword;
    if (creditToBeneficiary) {
      isIncome = false;
    } else if (!hasCreditKeyword && (hasDebitKeyword || mentionsTopUp)) {
      isIncome = false;
    } else if (hasCreditKeyword && hasDebitKeyword) {
      isIncome = normalizedBody.contains("credited to your") ||
          (normalizedBody.contains("credited to a/c") &&
              !normalizedBody.contains("beneficiary"));
    }

    return SmsHeuristicResult.approve(
      amount: candidate.value,
      currency: candidate.currency ?? "INR",
      isIncome: isIncome,
      normalizedSender: normalizedSender,
      normalizedBody: normalizedBody,
    );
  }

  bool _matchesSenderOrBody(String sender, String body) {
    for (final keyword in senderKeywords) {
      final normalizedKeyword = keyword.trim().toLowerCase();
      if (normalizedKeyword.isEmpty) continue;
      if (sender.contains(normalizedKeyword) ||
          body.contains(normalizedKeyword)) {
        return true;
      }
    }
    return false;
  }

  List<_AmountCandidate> _extractAmountCandidates(String body) {
    final matches = _amountRegex.allMatches(body);
    final results = <_AmountCandidate>[];
    for (final match in matches) {
      final rawAmount = match.group(2);
      if (rawAmount == null) continue;
      final normalizedAmount = rawAmount.replaceAll(RegExp(r'[,\s]'), '');
      final value = double.tryParse(normalizedAmount);
      if (value == null) continue;
      final prefixCurrency = match.group(1);
      final suffixCurrency = match.group(3);
      final currencyToken = prefixCurrency ?? suffixCurrency;
      final currency = _normalizeCurrencyToken(currencyToken);
      final snippetStart = (match.start - 20) < 0 ? 0 : match.start - 20;
      final snippetEnd =
          (match.end + 20) > body.length ? body.length : match.end + 20;
      final snippet = body.substring(snippetStart, snippetEnd);
      results.add(
        _AmountCandidate(
          value: value,
          currency: currency,
          contextSnippet: snippet,
          matchIndex: match.start,
        ),
      );
    }
    return results;
  }

  _AmountCandidate? _selectBestCandidate(
    List<_AmountCandidate> candidates,
  ) {
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;

    final prioritized =
        candidates.where((candidate) => candidate.hasTransactionCue).toList();
    if (prioritized.isNotEmpty) {
      prioritized.sort((a, b) => a.matchIndex.compareTo(b.matchIndex));
      return prioritized.first;
    }

    candidates.sort((a, b) => a.matchIndex.compareTo(b.matchIndex));
    return candidates.first;
  }

  String? _normalizeCurrencyToken(String? token) {
    if (token == null) return null;
    if (token.contains(_rupeeSymbol)) return "INR";
    final cleaned = token.replaceAll(RegExp(r'[^a-zA-Z]'), '').toUpperCase();
    if (cleaned.isEmpty) return null;
    switch (cleaned) {
      case "RS":
      case "INR":
        return "INR";
      default:
        return cleaned;
    }
  }
}

@pragma('vm:entry-point')
void onBackgroundMessage(SmsMessage message) async {
  print("Background SMS Received: ${message.body}");
  try {
    WidgetsFlutterBinding.ensureInitialized();
    final db = await platform.constructDb('db');
    print("Background DB Opened");

    final appSettingsEntry = await db.select(db.appSettings).getSingleOrNull();
    if (appSettingsEntry != null) {
      final decoded = json.decode(appSettingsEntry.settingsJSON);
      if (decoded is Map<String, dynamic>) {
        await processSms(
          message,
          db,
          Map<String, dynamic>.from(decoded),
        );
      } else {
        print("Background: Settings JSON malformed");
      }
    } else {
      print("Background: No AppSettings found in DB");
    }

    await db.close();
    print("Background DB Closed");
  } catch (e) {
    print("Error in background SMS processing: $e");
  }
}

Future<void> processSms(
  SmsMessage message,
  FinanceDatabase db,
  Map<String, dynamic> settings,
) async {
  final String apiKey = _safeStringSetting(settings, "openaiApiKey").trim();
  if (apiKey.isEmpty) {
    print("SMS ignored: API key missing");
    return;
  }

  final String modelSetting =
      _safeStringSetting(settings, "openaiModel", fallback: defaultOpenAiModel)
          .trim();
  final String model =
      modelSetting.isEmpty ? defaultOpenAiModel : modelSetting;
  String baseUrlSetting =
      _safeStringSetting(settings, "openaiBaseUrl", fallback: defaultOpenAiBaseUrl)
          .trim();
  if (baseUrlSetting.isEmpty) {
    baseUrlSetting = defaultOpenAiBaseUrl;
  }
  final Uri chatEndpoint = _buildChatCompletionsUri(baseUrlSetting);
  final String promptSetting =
      _safeStringSetting(settings, "smsPromptTemplate", fallback: defaultSmsPromptTemplate);
  final String systemPrompt =
      promptSetting.isEmpty ? defaultSmsPromptTemplate : promptSetting;
  final List<String> senderKeywords =
      _resolveSenderKeywords(settings["smsSenderKeywords"]);

  final heuristics = BankSmsHeuristics(senderKeywords: senderKeywords);
  final result = heuristics.evaluate(message);

  if (!result.shouldProcess) {
    print("SMS ignored: ${result.reason ?? "Heuristic rejection"}");
    return;
  }

  final heuristicsContext = result.toContext(message.address ?? "");
  final String walletPk = _resolveWalletPk(settings);
  final TransactionWallet? resolvedWallet =
      await _getWalletByPk(db, walletPk) ?? await _getFallbackWallet(db);
  final String effectiveWalletPk = resolvedWallet?.walletPk ?? walletPk;
  final String? walletCurrency = resolvedWallet?.currency?.toUpperCase();
  final payload = {
    "model": model,
    "temperature": 0.2,
    "max_tokens": 250,
    "messages": [
      {
        "role": "system",
        "content": systemPrompt
      },
      {
        "role": "user",
        "content":
            "SMS payload:\n${message.body ?? ""}\n\nHeuristic hints:\n${json.encode(heuristicsContext)}"
      }
    ]
  };

  try {
    http.Response? response;
    int retryCount = 0;
    const maxRetries = 3;

    // Retry logic for transient network errors
    while (retryCount < maxRetries) {
      try {
        response = await http
            .post(
              chatEndpoint,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              },
              body: json.encode(payload),
            )
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 200 || response.statusCode >= 400) {
          // Success or client error (don't retry client errors)
          break;
        }

        // Server error or rate limit - retry
        retryCount++;
        if (retryCount < maxRetries) {
          print("OpenAI API retry $retryCount/$maxRetries after ${response.statusCode}");
          await Future.delayed(Duration(seconds: retryCount * 2));
        }
      } on TimeoutException {
        retryCount++;
        if (retryCount < maxRetries) {
          print("OpenAI API timeout - retry $retryCount/$maxRetries");
          await Future.delayed(Duration(seconds: retryCount * 2));
        } else {
          rethrow;
        }
      }
    }

    if (response == null) {
      print("OpenAI API failed after $maxRetries retries");
      return;
    }

    print("OpenAI Response: ${response.statusCode}");

    if (response.statusCode != 200) {
      print("OpenAI API Error: ${response.body}");
      return;
    }

    final data = json.decode(response.body);
    final content = (data['choices'][0]['message']['content'] ?? "")
        .toString()
        .replaceAll("```json", "")
        .replaceAll("```", "")
        .trim();

    if (content.isEmpty || content.toLowerCase() == "null") {
      print("OpenAI returned null (not a transaction)");
      return;
    }

    dynamic extracted;
    try {
      extracted = json.decode(content);
    } catch (e) {
      print("Failed to decode OpenAI response: $e");
      return;
    }

    if (extracted is! Map<String, dynamic>) {
      print("Unexpected OpenAI response format");
      return;
    }

    // Validate required fields from OpenAI response
    if (!extracted.containsKey("amount") && result.signedAmount == null) {
      print("OpenAI response missing amount and no heuristic fallback");
      return;
    }

    if (!extracted.containsKey("title") || extracted["title"].toString().trim().isEmpty) {
      print("OpenAI response missing or empty title");
      return;
    }

    final double? openAiAmount = _coerceAmount(extracted["amount"]);
    double amount = openAiAmount ?? (result.signedAmount ?? 0);

    if (amount == 0) {
      print("No valid amount found after parsing");
      return;
    }

    if (result.isIncome != null) {
      if (result.isIncome! && amount < 0) {
        amount = amount.abs();
      } else if (!result.isIncome! && amount > 0) {
        amount = -amount.abs();
      }
    }

    final String? detectedCurrency = result.currency?.toUpperCase();
    final String? title = extracted["title"]?.toString();
    final String? categoryName = extracted["category"]?.toString();
    final String? dateString = extracted["date"]?.toString();
    final DateTime date =
        DateTime.tryParse(dateString ?? "") ?? DateTime.now();

    if (walletCurrency != null &&
        detectedCurrency != null &&
        detectedCurrency != walletCurrency) {
      final converted = _convertAmountToWalletCurrency(
        amount,
        detectedCurrency,
        walletCurrency,
        settings,
      );
      if (converted != null) {
        amount = converted;
      }
    }

    if (title == null || title.isEmpty) {
      print("Missing title from extraction");
      return;
    }

    final categories = await db.select(db.categories).get();
    if (categories.isEmpty) {
      throw Exception("No categories found");
    }

    final category = categories.firstWhere(
      (c) =>
          categoryName != null &&
          c.name.toLowerCase() == categoryName.toLowerCase(),
      orElse: () => categories.first,
    );

    final duplicateQuery = db.select(db.transactions)
      ..where((tbl) => tbl.amount.equals(amount))
      ..where((tbl) => tbl.note.equals(message.body ?? ""))
      ..where((tbl) => tbl.dateCreated
          .isBiggerOrEqualValue(DateTime.now().subtract(const Duration(minutes: 5))));
    final existing = await duplicateQuery.getSingleOrNull();
    if (existing != null) {
      print("Duplicate SMS transaction detected. Skipping insert.");
      return;
    }

    await db.into(db.transactions).insert(
          TransactionsCompanion(
            transactionPk: drift.Value.absent(),
            name: drift.Value(title),
            amount: drift.Value(amount),
            note: drift.Value(message.body ?? ""),
            categoryFk: drift.Value(category.categoryPk),
            walletFk: drift.Value(effectiveWalletPk),
            dateCreated: drift.Value(date),
            income: drift.Value(amount > 0),
            paid: drift.Value(true),
          ),
        );

    print("Transaction Successfully Added!");
  } on TimeoutException catch (e) {
    print("OpenAI request timed out: $e");
  } catch (e) {
    print("Error processing SMS: $e");
  }
}

List<String> _resolveSenderKeywords(dynamic value) {
  if (value is List) {
    return value
        .map((item) => item.toString().toLowerCase().trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList();
  }
  if (value is String && value.trim().isNotEmpty) {
    return value
        .split(RegExp(r'[,\n]'))
        .map((item) => item.trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList();
  }
  return List<String>.from(defaultSmsSenderKeywords);
}

String _safeStringSetting(
  Map<String, dynamic> settings,
  String key, {
  String fallback = "",
}) {
  final value = settings[key];
  if (value is String) return value;
  return fallback;
}

double? _coerceAmount(dynamic value) {
  if (value is int) return value.toDouble();
  if (value is double) return value;
  if (value is String) {
    final sanitized = value.replaceAll(RegExp(r'[^0-9\.\-]'), '');
    return double.tryParse(sanitized);
  }
  return null;
}

Uri _buildChatCompletionsUri(String baseUrl) {
  var normalized = baseUrl.trim();
  if (normalized.isEmpty) normalized = defaultOpenAiBaseUrl;
  if (!normalized.startsWith(RegExp(r'https?://'))) {
    normalized = 'https://$normalized';
  }
  if (normalized.contains("chat/completions")) {
    return Uri.parse(normalized);
  }
  if (!normalized.endsWith('/')) {
    normalized = '$normalized/';
  }
  return Uri.parse('${normalized}chat/completions');
}

String _resolveWalletPk(Map<String, dynamic> settings) {
  final dynamic selected = settings["selectedWalletPk"];
  if (selected == null) return "0";
  final value = selected.toString();
  return value.isEmpty ? "0" : value;
}

Future<TransactionWallet?> _getWalletByPk(
    FinanceDatabase db, String walletPk) async {
  return await (db.select(db.wallets)
        ..where((tbl) => tbl.walletPk.equals(walletPk)))
      .getSingleOrNull();
}

Future<TransactionWallet?> _getFallbackWallet(FinanceDatabase db) async {
  final wallets = await db.select(db.wallets).get();
  if (wallets.isEmpty) return null;
  return wallets.firstWhere(
    (wallet) => wallet.walletPk == "0",
    orElse: () => wallets.first,
  );
}

double? _convertAmountToWalletCurrency(
  double signedAmount,
  String fromCurrency,
  String toCurrency,
  Map<String, dynamic> settings,
) {
  final ratio = _currencyConversionRatio(fromCurrency, toCurrency, settings);
  if (ratio == null || ratio == 0) return null;
  final magnitude = signedAmount.abs() * ratio;
  return signedAmount >= 0 ? magnitude : -magnitude;
}

double? _currencyConversionRatio(
  String fromCurrency,
  String toCurrency,
  Map<String, dynamic> settings,
) {
  final double? fromRate = _lookupCurrencyRate(settings, fromCurrency);
  final double? toRate = _lookupCurrencyRate(settings, toCurrency);
  if (fromRate == null || toRate == null || fromRate == 0) return null;
  return toRate / fromRate;
}

double? _lookupCurrencyRate(
  Map<String, dynamic> settings,
  String currencyCode,
) {
  final String key = currencyCode.toLowerCase();
  final dynamic custom = settings["customCurrencyAmounts"];
  if (custom is Map && custom[key] != null) {
    return (custom[key] as num).toDouble();
  }
  final dynamic cached = settings["cachedCurrencyExchange"];
  if (cached is Map && cached[key] != null) {
    return (cached[key] as num).toDouble();
  }
  return null;
}

void initializeSmsListener() async {
  try {
    final telephony = Telephony.instance;
    bool? permissionsGranted = await telephony.requestPhoneAndSmsPermissions;

    if (permissionsGranted == true) {
      telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) {
          print("Foreground SMS Received");
          final currentSettings = Map<String, dynamic>.from(appStateSettings);
          final apiKey =
              _safeStringSetting(currentSettings, "openaiApiKey").trim();

          if (apiKey.isEmpty) {
            print("OpenAI API Key is missing in settings");
            return;
          }

          unawaited(processSms(message, database, currentSettings));
        },
        onBackgroundMessage: onBackgroundMessage,
      );
      print("SMS Listener Initialized");
    } else {
      print("SMS Permissions denied by user");
    }
  } catch (e) {
    print("Error initializing SMS listener: $e");
  }
}
