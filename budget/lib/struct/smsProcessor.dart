import 'package:telephony/telephony.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:drift/drift.dart' as drift;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter/material.dart';
import 'package:budget/database/platform/shared.dart' as platform; // Import for constructDb

@pragma('vm:entry-point')
void onBackgroundMessage(SmsMessage message) async {
  print("Background SMS Received: ${message.body}");
  try {
    // Necessary for plugins like path_provider used in constructDb
    WidgetsFlutterBinding.ensureInitialized();

    // Construct DB - assuming 'db' is the default name used in main.dart
    // We need to manually import where constructDb is defined.
    // It seems it is in 'package:budget/database/platform/native.dart' based on investigation
    // but usually exposed via a shared file or we can copy the logic if needed.
    // Let's try using the one from the investigation: platform/native.dart is where it was found.
    // But we need the import. constructDb is exported? 
    // 'budget/database/tables.dart' imports 'platform/shared.dart' which exports 'native.dart'.
    // So we might be able to call constructDb if it's globally available or imported.
    // Wait, `database/tables.dart` exports `platform/shared.dart`.
    // And `shared.dart` exports `native.dart` (conditionally).
    // So `constructDb` should be available if we import `tables.dart` or `platform/shared.dart`.
    // But `tables.dart` is already imported.
    // Let's check if constructDb is in scope.
    // It's in `native.dart`, and `shared.dart` exports it.
    
    final db = await platform.constructDb('db');
    
    print("Background DB Opened");

    // Fetch Settings
    final appSettingsEntry = await db.select(db.appSettings).getSingleOrNull();
    if (appSettingsEntry != null) {
       Map<String, dynamic> settings = json.decode(appSettingsEntry.settingsJSON);
       String? apiKey = settings["openaiApiKey"];
       
       if (apiKey != null && apiKey.isNotEmpty) {
         await processSms(message, db, apiKey);
       } else {
         print("Background: API Key not found in settings");
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

Future<void> processSms(SmsMessage message, FinanceDatabase db, String apiKey) async {
  String sender = (message.address ?? "").toLowerCase();
  String body = (message.body ?? "").toLowerCase();

  print("Processing SMS from $sender: $body");
  // Toast might not work well in background, but we can try. 
  // Often suppressed on newer Android versions from background services.
  
  // Filter: sender must contain "axis" or "icic", ignore "otp"
  if ((!sender.contains("axis") && !sender.contains("icic")) || body.contains("otp")) {
    print("SMS ignored: Filter mismatch");
    return;
  }

  print("SMS matched filter! Sending to OpenAI...");

  try {
    var response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: json.encode({
        "model": "gpt-4o-mini",
        "messages": [
          {
            "role": "system",
            "content": "Extract transaction details from this SMS. Return strictly valid JSON with no markdown formatting. JSON format: {\"title\": string, \"amount\": number (negative for expense, positive for income), \"category\": string, \"date\": string (ISO8601)}. If it is not a transaction, return null."
          },
          {
            "role": "user",
            "content": message.body
          }
        ],
        "max_tokens": 150
      }),
    );

    print("OpenAI Response: ${response.statusCode} ${response.body}");

    if (response.statusCode == 200) {
      var data = json.decode(response.body);
      var content = data['choices'][0]['message']['content'];
      content = content.replaceAll("```json", "").replaceAll("```", "").trim();
      
      var extracted = json.decode(content);
      if (extracted == null) {
        print("OpenAI returned null (not a transaction)");
        return;
      }

      double amount = (extracted['amount'] is int) ? (extracted['amount'] as int).toDouble() : extracted['amount'];
      String title = extracted['title'];
      String categoryName = extracted['category'];

      print("Extracted: $title, $amount, $categoryName");

      // Resolve Category (Fallback to first found if no match)
      var categories = await db.select(db.categories).get();
      var category = categories.firstWhere(
        (c) => c.name.toLowerCase() == categoryName.toLowerCase(),
        orElse: () => categories.isNotEmpty ? categories.first : throw Exception("No categories found"),
      );

      // Insert Transaction
      await db.into(db.transactions).insert(
        TransactionsCompanion(
          transactionPk: drift.Value.absent(),
          name: drift.Value(title),
          amount: drift.Value(amount),
          note: drift.Value(message.body ?? ""),
          categoryFk: drift.Value(category.categoryPk),
          walletFk: drift.Value("0"),
          dateCreated: drift.Value(DateTime.now()),
          income: drift.Value(amount > 0),
          paid: drift.Value(true),
        ),
      );
      
      print("Transaction Successfully Added!");
      
    } else {
      print("OpenAI API Error: ${response.body}");
    }
  } catch (e) {
    print("Error processing SMS: $e");
  }
}

void initializeSmsListener() async {
  try {
    final telephony = Telephony.instance;
    
    // Explicitly request permissions with a visual prompt
    bool? permissionsGranted = await telephony.requestPhoneAndSmsPermissions;
    
    if (permissionsGranted == true) {
      telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) {
           print("Foreground SMS Received");
           
           String apiKey = appStateSettings["openaiApiKey"] ?? "";
           
           if (apiKey.isNotEmpty) {
             processSms(message, database, apiKey);
           } else {
             print("OpenAI API Key is missing in settings");
           }
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
