import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await ProgressStore.init();
  runApp(const HandTalkApp());
}

// ===============================
// AUTH SERVICE (Firebase)
// ===============================

class AuthFailure implements Exception {
  final String message;

  /// Which field the problem belongs to: 'email' | 'password' | 'general'.
  /// Lets the login screen show the message right under the problem field.
  final String field;
  AuthFailure(this.message, {this.field = 'general'});
  @override
  String toString() => message;
}

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authChanges => _auth.authStateChanges();

  Future<void> signUpUser(String email, String password,
      {String? displayName}) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
      final name = displayName?.trim() ?? '';
      if (name.isNotEmpty) {
        // Save the typed name on this device first, so it always shows up.
        final uid = cred.user?.uid;
        if (uid != null) await ProgressStore.setSavedName(uid, name);
        try {
          await cred.user?.updateDisplayName(name);
          await cred.user?.reload();
        } catch (_) {}
      }
    } on FirebaseAuthException catch (e) {
      throw _failure(e.code);
    }
  }

  Future<void> signInUser(String email, String password) async {
    try {
      await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
    } on FirebaseAuthException catch (e) {
      throw _failure(e.code);
    }
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw _failure(e.code);
    }
  }

  Future<void> signOutUser() => _auth.signOut();

  // Plain-language messages: say what went wrong AND how to fix it.
  AuthFailure _failure(String code) {
    switch (code) {
      case 'invalid-email':
        return AuthFailure(
            'That email doesn\'t look right. Try something like name@example.com.',
            field: 'email');
      case 'user-not-found':
        return AuthFailure(
            'No account found with this email. Tap "Create an account" below.',
            field: 'email');
      case 'wrong-password':
      case 'invalid-credential':
        return AuthFailure(
            'Email or password is incorrect. Check both and try again, or tap Forgot Password.',
            field: 'password');
      case 'email-already-in-use':
        return AuthFailure(
            'This email already has an account. Try logging in instead.',
            field: 'email');
      case 'weak-password':
        return AuthFailure('Password is too weak. Use at least 6 characters.',
            field: 'password');
      case 'network-request-failed':
        return AuthFailure(
            'No internet connection. Check your Wi-Fi or data and try again.');
      case 'too-many-requests':
        return AuthFailure(
            'Too many attempts. Please wait a few minutes, then try again.');
      default:
        return AuthFailure('Something went wrong on our end. Please try again.');
    }
  }
}

// Name shown on the home screen: the name saved at sign-up / edited by the
// user, otherwise the Firebase display name, otherwise the email prefix.
String friendlyName(User? user) {
  if (user == null) return 'there';
  final saved = ProgressStore.savedName(user.uid);
  if (saved != null && saved.isNotEmpty) return saved;
  final display = user.displayName?.trim() ?? '';
  if (display.isNotEmpty) return display;
  final prefix = (user.email ?? '').split('@').first;
  final cleaned = prefix
      .replaceAll(RegExp(r'[0-9]+'), '')
      .replaceAll(RegExp(r'[._-]+'), ' ')
      .trim();
  if (cleaned.isEmpty) return 'there';
  return cleaned
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

/// True if the user has a real name (typed at sign-up or edited later).
bool hasName(User? user) {
  if (user == null) return false;
  final saved = ProgressStore.savedName(user.uid);
  if (saved != null && saved.isNotEmpty) return true;
  return (user.displayName?.trim() ?? '').isNotEmpty;
}

/// Name validation (error PREVENTION), shared by sign-up and the
/// "change name" dialog.
/// Returns an error message, or null if the name is fine.
/// Rule: the name must contain at least one letter. Numbers or symbols are
/// allowed next to letters, but can't make up the whole name.
String? nameError(String v) {
  final n = v.trim();
  if (n.isEmpty) return null; // don't scold a field the user hasn't touched
  if (!RegExp(r'\p{L}', unicode: true).hasMatch(n)) {
    return 'Your name needs at least one letter. Numbers or symbols alone won\'t work.';
  }
  return null;
}

Future<void> editDisplayName(BuildContext context, VoidCallback onDone,
    {String title = 'Your name'}) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  final controller =
      TextEditingController(text: hasName(user) ? friendlyName(user) : '');
  final newName = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final err = nameError(controller.text);
        final valid = controller.text.trim().isNotEmpty && err == null;
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            inputFormatters: [LengthLimitingTextInputFormatter(30)],
            onChanged: (_) => setLocal(() {}),
            decoration: InputDecoration(
              hintText: 'e.g. Jethro',
              errorText: err,
              errorMaxLines: 3,
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
                onPressed: valid
                    ? () => Navigator.pop(ctx, controller.text.trim())
                    : null,
                child: const Text('Save')),
          ],
        );
      },
    ),
  );
  if (newName == null || newName.isEmpty) return;
  await ProgressStore.setSavedName(user.uid, newName); // always saved locally
  try {
    await user.updateDisplayName(newName);
    await user.reload();
  } catch (_) {}
  onDone();
}

// SHARED STYLE CONSTANTS

const Color primaryColor = Color(0xFF5BA6C0);
const Color primaryShadow = Color(0xFF3E7E93);
const Color backgroundColor = Color(0xFFF7FAFB);
const Color fieldFillColor = Color(0xFFF3F7FA);
const Color categoryCardColor = Color(0xFFE7DCC6);
const Color categoryCardShadow = Color(0xFFCDBB94);
const Color flameColor = Color(0xFFFF9F1C);
const Color lockedNodeColor = Color(0xFFD8D2C4);
const Color lockedNodeShadow = Color(0xFFBEB79E);
const Color correctColor = Color(0xFF58C27D);
const Color incorrectColor = Color(0xFFE0584F);
const Color lightBlue = Color(0xFFE8F5FA);

// Hint card colors (warm amber so hints stand out from the blue question UI)
const Color hintColor = Color(0xFFFFF4DC);
const Color hintAccent = Color(0xFFE08A00);

/// Width / height of every sign photo (portrait 3:4, like a phone photo).
/// If your photos use a different ratio, change this one number and every
/// photo frame in the app resizes to match.
const double kSignAspect = 3 / 4;

// Dictionary, Quiz and Honor System
class SignEntry {
  final String word;
  final String category;
  final String howTo;

  /// One or more photos of the sign, in order.
  /// 1 photo  -> a still picture.
  /// 2+ photos -> a short "step by step" loop (for signs that move, like
  /// Thank you or Welcome).
  /// Empty    -> the placeholder hand icon is shown.
  final List<String> images;

  /// Optional short caption for each photo (same order as [images]).
  final List<String> captions;

  const SignEntry(
    this.word,
    this.category,
    this.howTo, {
    this.images = const [],
    this.captions = const [],
  });

  String get id => '${category}_$word';
}

const List<SignEntry> allSigns = [
  // Alphabets

  SignEntry(
      'A',
      'Alphabets',
      'Make a fist with your palm facing forward and rest your thumb against the side of your index finger.',
      images: ['assets/signs/a.png']),
  SignEntry(
      'B',
      'Alphabets',
      'Hold your hand up with fingers straight and together, and fold your thumb across your palm.',
      images: ['assets/signs/b.png']),
  SignEntry('C', 'Alphabets',
      'Curve your fingers and thumb into the shape of the letter C.',
      images: ['assets/signs/c.png']),
  SignEntry(
      'D',
      'Alphabets',
      'Point your index finger up and touch the tips of your other fingers to your thumb.',
      images: ['assets/signs/d.png']),
  SignEntry(
      'E',
      'Alphabets',
      'Curl your fingertips down toward your palm and tuck your thumb underneath them.',
      images: ['assets/signs/e.png']),
  SignEntry(
      'F',
      'Alphabets',
      'Touch your thumb and index finger together to make a circle, with the other three fingers up.',
      images: ['assets/signs/f.png']),

  // Numbers

  SignEntry('One', 'Numbers',
      'Hold up your index finger with your palm facing out.',
      images: ['assets/signs/one.png']),
  SignEntry('Two', 'Numbers', 'Hold up your index and middle fingers.',
      images: ['assets/signs/two.png']),
  SignEntry('Three', 'Numbers',
      'Hold up your thumb, index and middle fingers.',
      images: ['assets/signs/three.png']),
  SignEntry('Four', 'Numbers',
      'Hold up four fingers and tuck your thumb into your palm.',
      images: ['assets/signs/four.png']),
  SignEntry('Five', 'Numbers',
      'Open your whole hand with all five fingers spread.',
      images: ['assets/signs/five.png']),
  SignEntry('Six', 'Numbers',
      'Touch your thumb to your pinky and hold the other three fingers up.',
      images: ['assets/signs/six.png']),

  // Greetings
  // Signs that move use 2 photos. Add more photos to the list (and a caption
  // for each) if a sign needs more steps.

  SignEntry('Hello', 'Greetings',
      'Place a flat hand near your forehead and move it outward like a small salute.',
      images: ['assets/signs/hello.png']),
  SignEntry('Goodbye', 'Greetings',
      'Raise an open hand and fold your fingers down and up as if waving.',
      images: ['assets/signs/goodbye.png']),
  SignEntry('Thank you', 'Greetings',
      'Touch your fingertips to your chin and move your hand forward and down.',
      images: ['assets/signs/thankyou.png', 'assets/signs/thankyou2.png'],
      captions: [
        'Touch your fingertips to your chin',
        'Move your hand forward and down',
      ]),
  SignEntry('Please', 'Greetings',
      'Rub a flat hand in a circle on your chest.',
      images: ['assets/signs/please1.png']),
  SignEntry('Sorry', 'Greetings',
      'Make a fist and rub it in a circle on your chest.',
      images: ['assets/signs/sorry.png']),
  SignEntry('Welcome', 'Greetings',
      'Hold an open hand out and sweep it inward toward your body.',
      images: ['assets/signs/welcome1.png', 'assets/signs/welcome2.png'],
      captions: [
        'Hold an open hand out',
        'Sweep it inward toward your body',
      ]),

  // Colors

  SignEntry('Red', 'Colors',
      'Brush your index finger downward across your lips.',
      images: ['assets/signs/red.png']),
  SignEntry('Blue', 'Colors',
      'Make a B handshape and shake it slightly from the wrist.',
      images: ['assets/signs/blue.png']),
  SignEntry('Yellow', 'Colors',
      'Make a Y handshape and shake it slightly from the wrist.',
      images: ['assets/signs/yellow.png']),
  SignEntry('Purple', 'Colors',
      'Make a P handshape and shake it slightly from the wrist.',
      images: ['assets/signs/purple.png']),
  SignEntry('Black', 'Colors',
      'Drag your index finger across your forehead from left to right.',
      images: ['assets/signs/black.png']),
  SignEntry('White', 'Colors',
      'Place your fingertips on your chest and pull them outward, closing them together.',
      images: ['assets/signs/white.png']),

  // People & Family

  SignEntry('Mother', 'People & Family',
      'Tap your thumb against your chin with your hand open.',
      images: ['assets/signs/mother.png']),
  SignEntry('Father', 'People & Family',
      'Tap your thumb against your forehead with your hand open.',
      images: ['assets/signs/father.png']),
  SignEntry('Sister', 'People & Family',
      'Touch your thumb to your chin with a fist, then bring it down to your other hand.',
      images: ['assets/signs/sister.png']),
  SignEntry('Brother', 'People & Family',
      'Touch your thumb to your forehead with a fist, then bring it down to your other hand.',
      images: ['assets/signs/brother.png']),
  SignEntry('Baby', 'People & Family',
      'Cradle your arms together and rock them side to side.',
      images: ['assets/signs/baby.png', 'assets/signs/baby2.png'],
      captions: [
        'Cradle your arms together',
        'Rock them side to side',
      ]),
  SignEntry('Friend', 'People & Family',
      'Hook your index fingers together, then switch which one is on top.',
      images: ['assets/signs/friend.png']),
  SignEntry('Alone', 'People & Family',
      'Point your index finger up and move it in a small circle.',
      images: ['assets/signs/alone.png']),
];

List<SignEntry> signsFor(String category) =>
    allSigns.where((s) => s.category == category).toList();

// PROGRESS STORE

class ProgressStore {
  static late SharedPreferences _p;

  static Future<void> init() async {
    _p = await SharedPreferences.getInstance();
  }

  // Every account gets its own progress: all keys start with the user's id.
  static String get _u => FirebaseAuth.instance.currentUser?.uid ?? 'guest';

  // ---- onboarding seen flag ----
  static bool get onboarded => _p.getBool('onboarded') ?? false;
  static Future<void> setOnboarded() => _p.setBool('onboarded', true);

  // ---- "new here? see the FAQ" banner seen flag (per account) ----
  static bool get helpSeen => _p.getBool('${_u}_help_seen') ?? false;
  static Future<void> setHelpSeen() => _p.setBool('${_u}_help_seen', true);

  // ---- display name (per account, saved on this device) ----
  static String? savedName(String uid) => _p.getString('${uid}_name');
  static Future<void> setSavedName(String uid, String name) =>
      _p.setString('${uid}_name', name);

  // ---- "what should we call you?" asked once per account ----
  static bool get namePrompted => _p.getBool('${_u}_name_prompted') ?? false;
  static Future<void> setNamePrompted() =>
      _p.setBool('${_u}_name_prompted', true);

  // ---- daily streak (per account) ----
  // A day counts when the user opens the app while logged in. It only goes
  // up by 1 per day, no matter how many lessons or quizzes they do.
  // Miss a whole day and the streak restarts at 1.
  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String get _today => _dayKey(DateTime.now());

  static String get _yesterday {
    final n = DateTime.now();
    return _dayKey(DateTime(n.year, n.month, n.day - 1));
  }

  /// Current streak. Still shown today if the user last practiced yesterday
  /// (they have until the end of today to keep it alive); 0 once broken.
  static int get streak {
    final last = _p.getString('${_u}_streak_last');
    if (last == _today || last == _yesterday) {
      return _p.getInt('${_u}_streak_count') ?? 0;
    }
    return 0;
  }

  static bool get practicedToday =>
      _p.getString('${_u}_streak_last') == _today;

  /// Counts today toward the streak. Safe to call many times: it only counts
  /// once per day.
  static Future<void> recordActivity() async {
    final last = _p.getString('${_u}_streak_last');
    if (last == _today) return; // already counted today
    final int count =
        last == _yesterday ? (_p.getInt('${_u}_streak_count') ?? 0) + 1 : 1;
    await _p.setInt('${_u}_streak_count', count);
    await _p.setString('${_u}_streak_last', _today);
  }

  // ---- lessons completed per category ----
  static int completedLessons(String cat) =>
      _p.getInt('${_u}_completed_$cat') ?? 0;

  static Future<void> setCompletedLessons(String cat, int value) =>
      _p.setInt('${_u}_completed_$cat', value);

  // ---- honor system status per sign: 'got' | 'needs' | null ----
  static String? honor(SignEntry s) => _p.getString('${_u}_honor_${s.id}');

  static Future<void> setHonor(SignEntry s, bool got) =>
      _p.setString('${_u}_honor_${s.id}', got ? 'got' : 'needs');

  static bool isMastered(SignEntry s) => honor(s) == 'got';

  // ---- quiz in-progress (so the quiz can be resumed) ----
  static String _quizProgKey(String cat, String lesson) =>
      '${_u}_quizprog_${cat}_$lesson';

  static Map<String, dynamic>? quizProgress(String cat, String lesson) {
    final raw = _p.getString(_quizProgKey(cat, lesson));
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveQuizProgress(
      String cat, String lesson, int index, int correct) {
    return _p.setString(_quizProgKey(cat, lesson),
        jsonEncode({'index': index, 'correct': correct}));
  }

  static Future<void> clearQuizProgress(String cat, String lesson) =>
      _p.remove(_quizProgKey(cat, lesson));

  // ---- quiz final results ----
  static String _quizResKey(String cat, String lesson) =>
      '${_u}_quizres_${cat}_$lesson';

  static Map<String, dynamic>? quizResult(String cat, String lesson) {
    final raw = _p.getString(_quizResKey(cat, lesson));
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveQuizResult(
      String cat, String lesson, int score, int total) {
    final old = quizResult(cat, lesson);
    final best = old == null
        ? score
        : (score > (old['best'] as int) ? score : old['best'] as int);
    final attempts = (old?['attempts'] as int? ?? 0) + 1;
    return _p.setString(
      _quizResKey(cat, lesson),
      jsonEncode({
        'best': best,
        'last': score,
        'total': total,
        'attempts': attempts,
      }),
    );
  }
}

// APP
class HandTalkApp extends StatelessWidget {
  const HandTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hand Talk',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: primaryColor),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: primaryColor,
          selectionColor: Color(0x335BA6C0),
          selectionHandleColor: primaryColor,
        ),
        scaffoldBackgroundColor: backgroundColor,
      ),
      builder: (context, child) {
        // Keep the layout safe when a phone's system font size is very large.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(maxScaleFactor: 1.2),
          ),
          child: Container(
            color: const Color(0xFFE3E8EA),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Container(
                  clipBehavior: Clip.hardEdge,
                  decoration: const BoxDecoration(color: backgroundColor),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
      home: const SplashScreen(),
    );
  }
}

// SPLASH SCREEN

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  Timer? _timer;
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _fadeAnimation =
        CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);

    _timer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) {
            // Already logged in -> go straight to the app
            if (FirebaseAuth.instance.currentUser != null) {
              return const HomePage();
            }
            // Returning users skip onboarding
            return ProgressStore.onboarded
                ? const WelcomePage()
                : const OnboardingScreen();
          },
        ),
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: primaryColor,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.back_hand,
                    size: 100, color: Colors.white),
              ),
              const SizedBox(height: 24),
              const Text(
                'Hand Talk',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ONBOARDING SCREEN

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int currentPage = 0;
  final PageController pageController = PageController();

  final List<Map<String, dynamic>> pages = [
    {
      'title': 'Welcome to HandTalk!',
      'description':
          'A learning app designed to help you learn sign language in a simple and interactive way.',
      'icon': Icons.waving_hand,
    },
    {
      'title': 'Learning Made Fun',
      'description':
          'Learn ASL in a unique and fun way through interactive activities and engaging lessons.',
      'icon': Icons.auto_awesome,
    },
    {
      'title': 'Practice Through Interaction',
      'description':
          'Drag and drop tiles to choose your answer and practice recognizing signs through interactive quizzes. Your progress is saved automatically.',
      'icon': Icons.touch_app_rounded,
    },
    {
      'title': 'Learn Through the Honor System',
      'description':
          'Watch the tutorial, practice the sign yourself, and assess your performance using Yes, I Got It, Needs Work, or Replay Tutorial.',
      'icon': Icons.play_circle_outline_rounded,
    },
    {
      'title': 'Help is Always Here',
      'description':
          'Stuck or curious how something works? Open the Help tab at the bottom of the app anytime to read the FAQ.',
      'icon': Icons.help_outline_rounded,
    },
  ];

  void nextPage() {
    if (currentPage < pages.length - 1) {
      pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      goToWelcome();
    }
  }

  void skipPage() {
    goToWelcome();
  }

  void goToWelcome() {
    ProgressStore.setOnboarded();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const WelcomePage()),
    );
  }

  // Scroll-safe: on short phones the content scrolls instead of overflowing.
  Widget buildPage(IconData icon, String title, String description) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 160,
                  height: 160,
                  decoration: const BoxDecoration(
                    color: lightBlue,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 85, color: primaryColor),
                ),
                const SizedBox(height: 36),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.bold,
                    color: primaryColor,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Color(0xFF666666),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: skipPage,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, 48),
                  ),
                  child: const Text(
                    'SKIP',
                    style: TextStyle(
                      color: primaryColor,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: pageController,
                  itemCount: pages.length,
                  onPageChanged: (index) {
                    setState(() => currentPage = index);
                  },
                  itemBuilder: (context, index) {
                    return buildPage(
                      pages[index]['icon'] as IconData,
                      pages[index]['title'] as String,
                      pages[index]['description'] as String,
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(pages.length, (index) {
                  final bool isActive = currentPage == index;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: isActive ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: isActive
                          ? primaryColor
                          : primaryColor.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: nextPage,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    currentPage == pages.length - 1 ? 'GET STARTED' : 'NEXT',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

// CHUNKY 3D GAME BUTTON
class GameButton extends StatefulWidget {
  final String text;
  final Color color;
  final Color shadowColor;
  final Color textColor;
  final VoidCallback? onTap;
  final IconData? icon;
  final double height;
  final bool outlined;
  final Color? borderColor;

  const GameButton({
    super.key,
    required this.text,
    required this.color,
    required this.shadowColor,
    this.textColor = Colors.white,
    this.onTap,
    this.icon,
    this.height = 54,
    this.outlined = false,
    this.borderColor,
  });

  @override
  State<GameButton> createState() => _GameButtonState();
}

class _GameButtonState extends State<GameButton> {
  bool _pressed = false;
  static const double _depth = 6;
  static const Color _disabledColor = Color(0xFFDDE2E5);
  static const Color _disabledShadow = Color(0xFFC3C9CD);
  static const Color _disabledText = Color(0xFF8A9096);

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    final Color faceColor = enabled ? widget.color : _disabledColor;
    final Color shadowColor = enabled ? widget.shadowColor : _disabledShadow;
    final Color textColor = enabled ? widget.textColor : _disabledText;

    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap?.call();
            }
          : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      child: SizedBox(
        height: widget.height + _depth,
        child: Stack(
          children: [
            Positioned(
              top: _depth,
              left: 0,
              right: 0,
              child: Container(
                height: widget.height,
                decoration: BoxDecoration(
                  color: shadowColor,
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOut,
              top: _pressed ? _depth : 0,
              left: 0,
              right: 0,
              child: Container(
                height: widget.height,
                decoration: BoxDecoration(
                  color: faceColor,
                  borderRadius: BorderRadius.circular(18),
                  border: widget.outlined
                      ? Border.all(
                          color: enabled
                              ? (widget.borderColor ?? primaryColor)
                              : _disabledShadow,
                          width: 2,
                        )
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(widget.icon, color: textColor, size: 20),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===============================
// SHARED HELPERS (feedback, 48px exit button, exit confirmation)
// ===============================

void showMessage(BuildContext context, String message) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(message),
    duration: const Duration(seconds: 2),
  ));
}

class ExitButton extends StatelessWidget {
  final VoidCallback onPressed;
  const ExitButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Close',
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.close_rounded,
          color: Color(0xFF888888), size: 26),
      onPressed: onPressed,
    );
  }
}

Future<bool> confirmExit(BuildContext context) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Leave this lesson?'),
      content: const Text('Your progress so far is saved.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('STAY'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('LEAVE'),
        ),
      ],
    ),
  );
  return r ?? false;
}

// ===============================
// LOG OUT (error PREVENTION: ask before signing out)
// ===============================

/// Asks "are you sure?" before logging out. Returns true only if the user
/// explicitly taps LOG OUT. Tapping STAY or outside the dialog = false.
Future<bool> confirmLogout(BuildContext context) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.logout_rounded, color: incorrectColor, size: 40),
      title: const Text(
        'Log out of Hand Talk?',
        textAlign: TextAlign.center,
      ),
      content: const Text(
        'Don\'t worry, your progress is saved to your account. '
        'Log back in anytime and pick up right where you left off.',
        textAlign: TextAlign.center,
      ),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        // The safe choice comes first and is the filled button.
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: primaryColor,
            minimumSize: const Size(110, 48),
          ),
          onPressed: () => Navigator.pop(c, false),
          child: const Text('STAY',
              style: TextStyle(fontWeight: FontWeight.w800)),
        ),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(110, 48)),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('LOG OUT',
              style: TextStyle(
                  color: incorrectColor, fontWeight: FontWeight.w800)),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Highlighted, labeled log out button: red-tinted icon + the words "Log out"
/// so people recognise what it does before they ever tap it.
class LogoutButton extends StatelessWidget {
  final VoidCallback onPressed;
  const LogoutButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Log out',
      child: Tooltip(
        message: 'Log out',
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Container(
            width: 56,
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: incorrectColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: incorrectColor.withValues(alpha: 0.55), width: 1.5),
            ),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.logout_rounded, color: incorrectColor, size: 20),
                SizedBox(height: 1),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'Log out',
                    maxLines: 1,
                    style: TextStyle(
                      color: incorrectColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===============================
// HINT CARD (stands out from normal text: amber, labeled, bold)
// ===============================

class HintCard extends StatelessWidget {
  final String text;
  final String label;
  const HintCard({super.key, required this.text, this.label = 'HINT'});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: hintColor,
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: hintAccent.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lightbulb_rounded, size: 18, color: hintAccent),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                  color: hintAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF5A3B00),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

// HAND MASCOT (static, no bounce animation)

class HandMascot extends StatelessWidget {
  final double size;
  const HandMascot({super.key, this.size = 160});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primaryColor,
              border: Border.all(color: primaryShadow, width: 6),
            ),
          ),
          Icon(
            Icons.front_hand_rounded,
            size: size * 0.5,
            color: Colors.white,
          ),
        ],
      ),
    );
  }
}

// ===============================
// HAND TALK BADGE
// ===============================

class HandTalkBadge extends StatelessWidget {
  final double fontSize;
  const HandTalkBadge({super.key, this.fontSize = 16});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: primaryColor, width: 2),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.25),
            offset: const Offset(0, 3),
            blurRadius: 0,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, color: flameColor, size: fontSize + 4),
          const SizedBox(width: 6),
          Text(
            'HAND TALK',
            style: TextStyle(
              color: primaryColor,
              fontWeight: FontWeight.w800,
              fontSize: fontSize,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ===============================
// STREAK FLAME (real streak; grey when there is no active streak)
// ===============================

class StreakFlame extends StatelessWidget {
  final int days;
  const StreakFlame({super.key, required this.days});

  @override
  Widget build(BuildContext context) {
    final bool active = days > 0;
    final Color c = active ? flameColor : Colors.grey;
    return Semantics(
      label: active ? '$days day streak' : 'No streak yet',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_fire_department_rounded, color: c, size: 22),
            const SizedBox(width: 4),
            Text(
              '$days',
              style: const TextStyle(
                color: Color(0xFF222222),
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===============================
// DECORATIVE SPARKLES
// ===============================

class _Sparkle extends StatelessWidget {
  final double top, left, size, opacity;
  const _Sparkle({
    required this.top,
    required this.left,
    this.size = 18,
    this.opacity = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: left,
      child: Icon(
        Icons.star_rounded,
        size: size,
        color: primaryColor.withValues(alpha: opacity),
      ),
    );
  }
}

// ===============================
// WELCOME PAGE
// ===============================

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        // Scroll-safe: fills the screen on normal phones, scrolls on short ones.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Stack(
                  children: [
                    const _Sparkle(top: 40, left: 40, size: 16, opacity: 0.4),
                    const _Sparkle(top: 90, left: 280, size: 22, opacity: 0.35),
                    const _Sparkle(top: 20, left: 230, size: 12, opacity: 0.5),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 24),
                      child: Column(
                        children: [
                          const Spacer(),
                          const HandMascot(size: 170),
                          const SizedBox(height: 20),
                          const HandTalkBadge(),
                          const SizedBox(height: 18),
                          const Text(
                            'Learn ASL,\none sign at a time',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 27,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF222222),
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Master American Sign Language through playful '
                            'interactive games, bite-sized daily lessons, and '
                            'smart quiz challenges.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                              height: 1.5,
                            ),
                          ),
                          const Spacer(),
                          // GET STARTED -> sign up
                          GameButton(
                            text: 'GET STARTED',
                            color: primaryColor,
                            shadowColor: primaryShadow,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const LoginPage(signUp: true)),
                            ),
                          ),
                          const SizedBox(height: 14),
                          // I ALREADY HAVE AN ACCOUNT -> log in
                          GameButton(
                            text: 'I ALREADY HAVE AN ACCOUNT',
                            color: Colors.white,
                            shadowColor: const Color(0xFFE3E3E3),
                            textColor: primaryColor,
                            outlined: true,
                            borderColor: primaryColor,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const LoginPage()),
                            ),
                          ),
                          const SizedBox(height: 4),
                          // Account help is findable before the user even signs up
                          TextButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const FaqPage(
                                      title: 'Sign up & log in help',
                                      faqs: authFaqs)),
                            ),
                            style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48)),
                            icon: const Icon(Icons.help_outline_rounded,
                                size: 18, color: primaryColor),
                            label: const Text(
                              'Need help signing up?',
                              style: TextStyle(
                                  color: primaryColor,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ===============================
// LOGIN / SIGN UP PAGE (Firebase)
// ===============================

class LoginPage extends StatefulWidget {
  final bool signUp;
  const LoginPage({super.key, this.signUp = false});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _auth = AuthService();
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  late bool isSignUp = widget.signUp;
  bool obscurePassword = true;
  bool loading = false;

  // Errors that come back from Firebase, shown under the matching field.
  String? serverEmailError;
  String? serverPasswordError;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  // ---- validation (error PREVENTION: catch mistakes before submitting) ----

  String? _emailError(String v) {
    final e = v.trim();
    if (e.isEmpty) return null; // don't scold a field the user hasn't touched
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) {
      return 'Enter a valid email, like name@example.com.';
    }
    return serverEmailError;
  }

  String? _passwordError(String v) {
    if (v.isEmpty) return null;
    if (isSignUp && v.length < 6) return 'Use at least 6 characters.';
    return serverPasswordError;
  }

  bool get _formValid {
    final email = emailController.text.trim();
    final pass = passwordController.text;
    // Sign up needs a name with at least one letter
    final nameOk = !isSignUp ||
        (nameController.text.trim().isNotEmpty &&
            nameError(nameController.text) == null);
    return nameOk &&
        email.isNotEmpty &&
        pass.isNotEmpty &&
        _emailError(email) == null &&
        _passwordError(pass) == null;
  }

  void _clearServerErrors() {
    serverEmailError = null;
    serverPasswordError = null;
  }

  Future<void> _submit() async {
    if (!_formValid) return;
    final email = emailController.text.trim();
    final pass = passwordController.text.trim();
    setState(() {
      loading = true;
      _clearServerErrors();
    });
    try {
      if (isSignUp) {
        await _auth.signUpUser(email, pass, displayName: nameController.text);
        if (!mounted) return;
        // Clear feedback that the account now exists.
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.check_circle_rounded,
                color: correctColor, size: 48),
            title: const Text('Account created!'),
            content: Text(
              'Welcome to Hand Talk, '
              '${friendlyName(FirebaseAuth.instance.currentUser)}. '
              'Your progress will be saved to this account.',
              textAlign: TextAlign.center,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('START LEARNING'),
              ),
            ],
          ),
        );
      } else {
        // Logging in: make sure the user actually gets signed in.
        await _auth.signInUser(email, pass);
      }
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
        (route) => false,
      );
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.field == 'email') {
          serverEmailError = e.message;
        } else if (e.field == 'password') {
          serverPasswordError = e.message;
        } else {
          showMessage(context, e.message);
        }
      });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = emailController.text.trim();
    if (email.isEmpty) {
      showMessage(context, 'Type your email above first, then tap Forgot Password.');
      return;
    }
    if (_emailError(email) != null) {
      showMessage(context, 'Enter a valid email first, like name@example.com.');
      return;
    }
    try {
      await _auth.sendPasswordReset(email);
      if (mounted) {
        showMessage(context, 'Password reset email sent. Check your inbox.');
      }
    } on AuthFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  InputDecoration fieldDecoration(String hint, IconData icon,
      {String? errorText, String? helperText}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: Colors.grey[500], fontSize: 14),
      prefixIcon: Icon(icon, color: primaryColor, size: 20),
      filled: true,
      fillColor: fieldFillColor,
      errorText: errorText,
      errorMaxLines: 3,
      helperText: helperText,
      helperMaxLines: 2,
      errorStyle: const TextStyle(
          color: incorrectColor, fontSize: 12, fontWeight: FontWeight.w600),
      contentPadding: const EdgeInsets.symmetric(vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide:
            BorderSide(color: primaryColor.withValues(alpha: 0.35), width: 2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide:
            BorderSide(color: primaryColor.withValues(alpha: 0.35), width: 2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: primaryColor, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: incorrectColor, width: 2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: incorrectColor, width: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: 'Back',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: Color(0xFF222222)),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              const Center(child: HandMascot(size: 90)),
              const SizedBox(height: 16),
              const Center(child: HandTalkBadge()),
              const SizedBox(height: 24),
              Text(
                isSignUp ? 'Create account' : 'Log in',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF222222)),
              ),
              const SizedBox(height: 28),
              if (isSignUp) ...[
                TextField(
                  controller: nameController,
                  cursorColor: primaryColor,
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization.words,
                  inputFormatters: [LengthLimitingTextInputFormatter(30)],
                  onChanged: (_) => setState(() {}),
                  decoration: fieldDecoration('Your name', Icons.person_outline,
                      errorText: nameError(nameController.text),
                      helperText: 'Must include at least one letter'),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                cursorColor: primaryColor,
                onChanged: (_) => setState(() => serverEmailError = null),
                decoration: fieldDecoration('Email', Icons.email_outlined,
                    errorText: _emailError(emailController.text)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: obscurePassword,
                textInputAction: TextInputAction.done,
                cursorColor: primaryColor,
                onChanged: (_) => setState(() => serverPasswordError = null),
                onSubmitted: (_) {
                  if (!loading && _formValid) _submit();
                },
                decoration: fieldDecoration(
                  'Password',
                  Icons.lock_outline,
                  errorText: _passwordError(passwordController.text),
                  helperText: isSignUp ? 'At least 6 characters' : null,
                ).copyWith(
                  suffixIcon: IconButton(
                    tooltip:
                        obscurePassword ? 'Show password' : 'Hide password',
                    icon: Icon(
                      obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: Colors.grey[500],
                      size: 20,
                    ),
                    onPressed: () =>
                        setState(() => obscurePassword = !obscurePassword),
                  ),
                ),
              ),
              if (!isSignUp)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _forgotPassword,
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    child: const Text('Forgot Password?',
                        style: TextStyle(
                            color: primaryColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline)),
                  ),
                )
              else
                const SizedBox(height: 8),
              const SizedBox(height: 12),
              GameButton(
                text: loading
                    ? 'PLEASE WAIT...'
                    : (isSignUp ? 'SIGN UP' : 'LOG IN'),
                color: primaryColor,
                shadowColor: primaryShadow,
                // Disabled until the form is valid (error prevention)
                onTap: (loading || !_formValid) ? null : _submit,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() {
                  isSignUp = !isSignUp;
                  _clearServerErrors();
                }),
                child: Text(
                  isSignUp
                      ? 'Already have an account? Log in'
                      : 'New here? Create an account',
                  style: const TextStyle(
                      color: primaryColor, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const FaqPage(
                          title: 'Sign up & log in help', faqs: authFaqs)),
                ),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.help_outline_rounded,
                    size: 18, color: primaryColor),
                label: const Text('Need help signing up?',
                    style: TextStyle(
                        color: primaryColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===============================
// HOME DATA
// ===============================

class CategoryData {
  final String title;
  final int lessons;
  final IconData icon;

  const CategoryData({
    required this.title,
    required this.lessons,
    required this.icon,
  });
}

const List<CategoryData> categories = [
  CategoryData(title: 'Alphabets', lessons: 24, icon: Icons.abc_rounded),
  CategoryData(title: 'Numbers', lessons: 20, icon: Icons.pin_rounded),
  CategoryData(
      title: 'Greetings', lessons: 16, icon: Icons.emoji_people_rounded),
  CategoryData(title: 'Colors', lessons: 18, icon: Icons.palette_outlined),
  CategoryData(
      title: 'People & Family',
      lessons: 22,
      icon: Icons.people_alt_outlined),
];

// ===============================
// HOME PAGE (4 tabs: Dictionary / Home / Practice / Help)
// ===============================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int currentTab = 1;
  late bool showHelpBanner = !ProgressStore.helpSeen;

  @override
  void initState() {
    super.initState();
    // One streak point per day, counted when the user opens the app logged in.
    ProgressStore.recordActivity().then((_) {
      if (mounted) setState(() {});
    });

    // Existing accounts with no saved name: ask once.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final user = FirebaseAuth.instance.currentUser;
      if (!mounted || user == null) return;
      if (!hasName(user) && !ProgressStore.namePrompted) {
        await ProgressStore.setNamePrompted();
        if (!mounted) return;
        await editDisplayName(context, refresh,
            title: 'What should we call you?');
      }
    });
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  void _openTab(int index) {
    setState(() {
      currentTab = index;
      // Visiting Help counts as "seen", so the banner goes away for good.
      if (index == 3 && showHelpBanner) {
        showHelpBanner = false;
        ProgressStore.setHelpSeen();
      }
    });
  }

  void _dismissHelpBanner() {
    setState(() => showHelpBanner = false);
    ProgressStore.setHelpSeen();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: IndexedStack(
          index: currentTab,
          children: [
            const DictionaryView(),
            _HomeContent(
              onProgressChanged: refresh,
              showHelpBanner: showHelpBanner,
              onOpenHelp: () => _openTab(3),
              onDismissHelp: _dismissHelpBanner,
            ),
            PracticeView(onChanged: refresh),
            // Help tab: FAQ about using the app (learning), not about accounts
            const FaqView(title: 'Help & FAQ', faqs: homeFaqs),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            color: primaryColor,
            borderRadius: BorderRadius.circular(24),
            border: Border(bottom: BorderSide(color: primaryShadow, width: 5)),
          ),
          child: Row(
            children: [
              navIcon(Icons.menu_book_rounded, 'Dictionary', 0),
              navIcon(Icons.home_rounded, 'Home', 1),
              navIcon(Icons.play_lesson_rounded, 'Practice', 2),
              navIcon(Icons.help_outline_rounded, 'Help', 3),
            ],
          ),
        ),
      ),
    );
  }

  // Large, labeled tab (Fitts's law + Norman's signifier)
  Widget navIcon(IconData icon, String label, int index) {
    final bool selected = currentTab == index;
    final Color c =
        selected ? Colors.white : Colors.white.withValues(alpha: 0.6);
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openTab(index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 63,
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
            decoration: BoxDecoration(
              color: selected
                  ? Colors.white.withValues(alpha: 0.2)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 26, color: c),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: c,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// One-time "new here?" banner that points to the Help tab.
class _HelpBanner extends StatelessWidget {
  final VoidCallback onOpen;
  final VoidCallback onDismiss;
  const _HelpBanner({required this.onOpen, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
      decoration: BoxDecoration(
        color: lightBlue,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primaryColor.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Row(
        children: [
          const Icon(Icons.help_outline_rounded, color: primaryColor, size: 22),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'New here? See how Hand Talk works in the Help tab.',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF222222),
                  height: 1.3),
            ),
          ),
          TextButton(
            onPressed: onOpen,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: const Text('OPEN',
                style: TextStyle(
                    color: primaryColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 12)),
          ),
          IconButton(
            tooltip: 'Dismiss',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close_rounded,
                size: 20, color: Color(0xFF888888)),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  final VoidCallback onProgressChanged;
  final bool showHelpBanner;
  final VoidCallback onOpenHelp;
  final VoidCallback onDismissHelp;

  const _HomeContent({
    required this.onProgressChanged,
    required this.showHelpBanner,
    required this.onOpenHelp,
    required this.onDismissHelp,
  });

  @override
  Widget build(BuildContext context) {
    // Logged-in user's name
    final name = friendlyName(FirebaseAuth.instance.currentUser);

    final int mastered = allSigns.where(ProgressStore.isMastered).length;
    final double progress = mastered / allSigns.length;

    // Real streak (goes up once per day)
    final int streak = ProgressStore.streak;
    final String badge = streak > 0 ? 'STREAK ACTIVE' : 'START YOUR STREAK';
    final String streakTitle =
        streak > 0 ? '$streak Day Streak!' : 'No streak yet';
    final String streakNote = streak <= 1
        ? 'Come back tomorrow to grow your streak.'
        : 'Open the app every day to keep it going!';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Row(
            children: [
              const HandMascot(size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$name, check out today\'s lesson!',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    ),
                    GestureDetector(
                      onTap: () =>
                          editDisplayName(context, onProgressChanged),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              'Hi, $name!',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF222222),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.edit_rounded,
                              size: 15, color: primaryColor),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              StreakFlame(days: streak),
              const SizedBox(width: 8),
              // Highlighted, labeled log out button. Asks "are you sure?"
              // first so nobody signs out by accident.
              LogoutButton(
                onPressed: () async {
                  final sure = await confirmLogout(context);
                  if (!sure) return;
                  await AuthService().signOutUser();
                  if (!context.mounted) return;
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const WelcomePage()),
                    (route) => false,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: primaryColor,
              borderRadius: BorderRadius.circular(20),
              border:
                  Border(bottom: BorderSide(color: primaryShadow, width: 5)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          badge,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.local_fire_department_rounded,
                              color: streak > 0
                                  ? flameColor
                                  : Colors.white.withValues(alpha: 0.6),
                              size: 22),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              streakTitle,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$mastered of ${allSigns.length} signs mastered.\n$streakNote',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 60,
                  height: 60,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 60,
                        height: 60,
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 5,
                          backgroundColor: Colors.white.withValues(alpha: 0.25),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.white),
                        ),
                      ),
                      Text(
                        '${(progress * 100).round()}%',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (showHelpBanner)
            _HelpBanner(onOpen: onOpenHelp, onDismiss: onDismissHelp),
          const SizedBox(height: 22),
          const Text(
            'Learn Categories',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: Color(0xFF222222)),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.only(bottom: 20),
              itemCount: categories.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.92,
              ),
              itemBuilder: (context, index) => CategoryCard(
                data: categories[index],
                onReturn: onProgressChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===============================
// FAQ
//   authFaqs -> only on Welcome / Sign up / Log in (account help)
//   homeFaqs -> only on the Home "Help" tab (learning help)
// ===============================

// FAQ for the Welcome / Sign up / Log in screens
const List<(String, String)> authFaqs = [
  ('Do I need an account?',
      'Yes. Your account keeps your lessons, quiz results, streak and practice ratings saved, and keeps them separate from other people using this phone.'),
  ('How do I create an account?',
      'Tap GET STARTED, then enter your name, email and a password. The SIGN UP button turns on once everything is filled in correctly.'),
  ('What name can I use?',
      'Anything you like, as long as it has at least one letter, for example "Jethro" or "Sam 2". A name made only of numbers or symbols is not accepted.'),
  ('What makes a valid password?',
      'At least 6 characters. Tap the eye icon in the password box to check what you typed.'),
  ('I already have an account. How do I log in?',
      'Tap "I already have an account" on the first screen, or tap "Already have an account? Log in" at the bottom of the sign-up form.'),
  ('It says my email already has an account.',
      'That means you signed up before. Tap "Already have an account? Log in" and use the same email.'),
  ('I forgot my password.',
      'On the Log in screen, type your email and tap "Forgot Password?". We will email you a reset link. If you don\'t see it, check your spam folder.'),
  ('It says there is no internet connection.',
      'Sign up and log in need Wi-Fi or mobile data. Check your connection and try again.'),
];

// FAQ for the Help tab on the Home screen
const List<(String, String)> homeFaqs = [
  ('How do lessons work?',
      'Each category has a path. Lesson 1.1 teaches you the signs, 1.2 is a drag-and-drop quiz, and the next lessons are practice rounds. Finish one lesson to unlock the next.'),
  ('How do I take the quiz?',
      'Look at the sign photo, then drag the correct word into the box. Tap "Show hint" if you are stuck. A wrong answer lets you try again.'),
  ('What does the Honor System mean?',
      'You watch the sign, copy it with your own hand, then rate yourself honestly: "Yes, I got it" or "Needs work". Signs marked "Needs work" come back at the end.'),
  ('What do "Learned" and "Needs work" mean?',
      'They show your own ratings from Practice. "Learned" signs count toward your mastery percentage on the Home screen.'),
  ('How does the streak work?',
      'Your streak goes up by 1 for each day you open Hand Talk while logged in, no matter how many lessons you do. If you miss a whole day, it starts again at 1.'),
  ('How do I find a specific sign?',
      'Open the Dictionary tab, then use the search bar or the menu button to filter by category.'),
  ('Is my progress saved?',
      'Yes. Quiz progress, lesson completion, streak and practice ratings are saved on this device under your account.'),
  ('How do I change my name?',
      'On the Home screen, tap your name in "Hi, ...!" and type a new one. It needs at least one letter.'),
  ('How do I log out?',
      'Tap the red "Log out" button at the top right of the Home screen, next to your streak. We will ask you to confirm, so you can\'t log out by accident. Your progress stays saved to your account.'),
];

class FaqPage extends StatelessWidget {
  final String title;
  final List<(String, String)> faqs;
  const FaqPage({super.key, required this.title, required this.faqs});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
          child: FaqView(title: title, faqs: faqs, showBack: true)),
    );
  }
}

class FaqView extends StatelessWidget {
  final String title;
  final List<(String, String)> faqs;
  final bool showBack;
  const FaqView({
    super.key,
    required this.faqs,
    this.title = 'Help & FAQ',
    this.showBack = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showBack)
                IconButton(
                  tooltip: 'Back',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: Color(0xFF222222)),
                  onPressed: () => Navigator.pop(context),
                )
              else
                const SizedBox(height: 48),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF222222))),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('Tap a question to see the answer.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 20),
              itemCount: faqs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final (q, a) = faqs[i];
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: primaryColor.withValues(alpha: 0.2), width: 1.5),
                  ),
                  child: Theme(
                    data: Theme.of(context)
                        .copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                      childrenPadding:
                          const EdgeInsets.fromLTRB(14, 0, 14, 14),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      iconColor: primaryColor,
                      collapsedIconColor: primaryColor,
                      title: Text(q,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF222222))),
                      children: [
                        Text(a,
                            style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: Colors.grey[700])),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ===============================
// CATEGORY CARD
// ===============================

class CategoryCard extends StatefulWidget {
  final CategoryData data;
  final VoidCallback? onReturn;
  const CategoryCard({super.key, required this.data, this.onReturn});

  @override
  State<CategoryCard> createState() => _CategoryCardState();
}

class _CategoryCardState extends State<CategoryCard> {
  bool _pressed = false;
  static const double _depth = 5;

  Future<void> _openLessonPath() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LessonPathPage(category: widget.data),
      ),
    );
    widget.onReturn?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        _openLessonPath();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: Stack(
        children: [
          Positioned.fill(
            top: _depth,
            child: Container(
              decoration: BoxDecoration(
                color: categoryCardShadow,
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            margin: EdgeInsets.only(
                bottom: _pressed ? 0 : _depth, top: _pressed ? _depth : 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: categoryCardColor,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        widget.data.title,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF222222)),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10)),
                      child:
                          Icon(widget.data.icon, size: 16, color: primaryColor),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text('${widget.data.lessons} lessons',
                    style: TextStyle(fontSize: 10, color: Colors.grey[700])),
                const Spacer(),
                GameButton(
                  text: 'START',
                  color: primaryColor,
                  shadowColor: primaryShadow,
                  height: 40,
                  onTap: _openLessonPath,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===============================
// LESSON PATH PAGE
//   1.1  Learn     (LearnPage)
//   1.2  Quiz      (DragDropQuizPage)
//   1.3+ Practice  (HonorSystemPage)
// A green line connects each finished lesson to the next one.
// ===============================

class LessonNodeData {
  final String label;
  final String kind; // 'Learn' | 'Quiz' | 'Practice'
  final bool unlocked;
  final bool completed;
  final Alignment align;

  const LessonNodeData({
    required this.label,
    required this.kind,
    required this.unlocked,
    required this.completed,
    required this.align,
  });
}

class LessonPathPage extends StatefulWidget {
  final CategoryData category;
  const LessonPathPage({super.key, required this.category});

  @override
  State<LessonPathPage> createState() => _LessonPathPageState();
}

class _LessonPathPageState extends State<LessonPathPage> {
  late int nodeCount;
  late int completed; // saved: number of lessons completed

  static const double _nodeSize = 76;
  static const double _itemHeight = 120; // vertical distance between nodes
  static const double _nodeCenterY = 38; // _nodeSize / 2

  @override
  void initState() {
    super.initState();
    nodeCount = widget.category.lessons > 6 ? 6 : widget.category.lessons;
    completed = ProgressStore.completedLessons(widget.category.title)
        .clamp(0, nodeCount);
  }

  String _kindFor(int i) => i == 0 ? 'Learn' : (i == 1 ? 'Quiz' : 'Practice');

  List<LessonNodeData> get nodes => List.generate(
        nodeCount,
        (i) => LessonNodeData(
          label: '1.${i + 1}',
          kind: _kindFor(i),
          unlocked: i <= completed,
          completed: i < completed,
          align: i.isEven ? Alignment.topLeft : Alignment.topRight,
        ),
      );

  /// Two signs per honor-system lesson (lessons 1.3 and up).
  List<SignEntry> _lessonSigns(int lessonIndex) {
    final signs = signsFor(widget.category.title);
    final start = ((lessonIndex - 2) * 2) % signs.length;
    return [signs[start], signs[(start + 1) % signs.length]];
  }

  Future<void> _openLesson(int index) async {
    if (index > completed) {
      // Informative feedback instead of a silent failure
      showMessage(context, 'Finish the previous lesson to unlock this one.');
      return;
    }
    final label = '1.${index + 1}';

    final Widget page;
    if (index == 0) {
      page = LearnPage(category: widget.category);
    } else if (index == 1) {
      page = DragDropQuizPage(category: widget.category, lessonLabel: label);
    } else {
      page = HonorSystemPage(
        title: '${widget.category.title} · $label',
        signs: _lessonSigns(index),
      );
    }

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => page),
    );

    if (result == true && index + 1 > completed) {
      await ProgressStore.setCompletedLessons(
          widget.category.title, index + 1);
      completed = index + 1;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final nodeList = nodes;
    // The quiz is lesson 1.2
    final quizResult =
        ProgressStore.quizResult(widget.category.title, '1.2');

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    constraints:
                        const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Color(0xFF222222)),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      widget.category.title,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF222222)),
                    ),
                  ),
                  StreakFlame(days: ProgressStore.streak),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: primaryColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border(
                      bottom: BorderSide(color: primaryShadow, width: 5)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'MODULE 1',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$completed of $nodeCount lessons complete.\nStart with Learn, then test yourself.',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 11,
                                height: 1.3),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 46,
                      height: 46,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 46,
                            height: 46,
                            child: CircularProgressIndicator(
                              value: completed / nodeCount,
                              strokeWidth: 4,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.25),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                  Colors.white),
                            ),
                          ),
                          Icon(widget.category.icon,
                              color: Colors.white, size: 18),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                // The connector lines are drawn slightly outside each item's
                // box, so don't wrap items in clipping repaint boundaries.
                addRepaintBoundaries: false,
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
                itemCount: nodeList.length,
                itemBuilder: (context, index) {
                  final node = nodeList[index];
                  final bool isLast = index == nodeList.length - 1;
                  final bool onRight = node.align == Alignment.topRight;

                  final caption = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: onRight
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.kind,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: node.unlocked
                              ? const Color(0xFF222222)
                              : Colors.grey[500],
                        ),
                      ),
                      if (index == 1 && quizResult != null)
                        Text(
                          'Best: ${quizResult['best']}/${quizResult['total']}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey[600],
                          ),
                        ),
                    ],
                  );

                  final nodeWidget = LessonNode(
                    data: node,
                    onTap: () => _openLesson(index),
                  );

                  return SizedBox(
                    height: _itemHeight,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final w = constraints.maxWidth;
                        const half = _nodeSize / 2;
                        final x1 = onRight ? w - half : half;
                        final x2 = onRight ? half : w - half;

                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // Line to the NEXT node: grey, and it fills in
                            // green (animated) once THIS lesson is completed.
                            if (!isLast)
                              Positioned.fill(
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween<double>(
                                      end: node.completed ? 1.0 : 0.0),
                                  duration: const Duration(milliseconds: 800),
                                  curve: Curves.easeInOut,
                                  builder: (context, value, _) => CustomPaint(
                                    painter: PathConnectorPainter(
                                      from: Offset(x1, _nodeCenterY),
                                      to: Offset(
                                          x2, _itemHeight + _nodeCenterY),
                                      progress: value,
                                    ),
                                  ),
                                ),
                              ),
                            Align(
                              alignment: node.align,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: onRight
                                    ? [
                                        caption,
                                        const SizedBox(width: 10),
                                        nodeWidget,
                                      ]
                                    : [
                                        nodeWidget,
                                        const SizedBox(width: 10),
                                        caption,
                                      ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Draws the curved line between two lesson nodes.
// Grey track underneath, green fill on top (progress 0..1).
class PathConnectorPainter extends CustomPainter {
  final Offset from;
  final Offset to;
  final double progress;

  PathConnectorPainter({
    required this.from,
    required this.to,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final midY = (from.dy + to.dy) / 2;
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..cubicTo(from.dx, midY, to.dx, midY, to.dx, to.dy);

    final track = Paint()
      ..color = lockedNodeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, track);

    if (progress > 0) {
      final fill = Paint()
        ..color = correctColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round;
      for (final metric in path.computeMetrics()) {
        canvas.drawPath(metric.extractPath(0, metric.length * progress), fill);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PathConnectorPainter old) =>
      old.progress != progress || old.from != from || old.to != to;
}

// ===============================
// LESSON NODE (path bubble)
// ===============================

class LessonNode extends StatefulWidget {
  final LessonNodeData data;
  final VoidCallback onTap;

  const LessonNode({super.key, required this.data, required this.onTap});

  @override
  State<LessonNode> createState() => _LessonNodeState();
}

class _LessonNodeState extends State<LessonNode> {
  bool _pressed = false;
  static const double _depth = 6;
  static const double _size = 76;

  @override
  Widget build(BuildContext context) {
    final bool unlocked = widget.data.unlocked;
    final bool done = widget.data.completed;
    final Color faceColor = done
        ? correctColor
        : (unlocked ? primaryColor : lockedNodeColor);
    final Color shadowColor = done
        ? const Color(0xFF3F9C5D)
        : (unlocked ? primaryShadow : lockedNodeShadow);

    return GestureDetector(
      // Locked nodes still respond (with an explanation) instead of ignoring the tap
      onTap: unlocked ? null : widget.onTap,
      onTapDown: unlocked ? (_) => setState(() => _pressed = true) : null,
      onTapUp: unlocked
          ? (_) {
              setState(() => _pressed = false);
              widget.onTap();
            }
          : null,
      onTapCancel: unlocked ? () => setState(() => _pressed = false) : null,
      child: SizedBox(
        width: _size,
        height: _size + _depth,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Positioned(
              top: _depth,
              child: Container(
                width: _size,
                height: _size,
                decoration:
                    BoxDecoration(color: shadowColor, shape: BoxShape.circle),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOut,
              top: _pressed ? _depth : 0,
              child: Container(
                width: _size,
                height: _size,
                decoration:
                    BoxDecoration(color: faceColor, shape: BoxShape.circle),
                child: Center(
                  child: done
                      ? const Icon(Icons.check_rounded,
                          color: Colors.white, size: 36)
                      : unlocked
                          ? Text(
                              widget.data.label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            )
                          : const Icon(Icons.lock_rounded,
                              color: Color(0xFF8A8367), size: 26),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===============================
// LEARN PAGE (lesson x.1)
// Teaches every sign in the category BEFORE any quiz, so first-time users
// aren't tested on things they've never seen.
// ===============================

class LearnPage extends StatefulWidget {
  final CategoryData category;
  const LearnPage({super.key, required this.category});

  @override
  State<LearnPage> createState() => _LearnPageState();
}

class _LearnPageState extends State<LearnPage> {
  late final List<SignEntry> signs;
  int index = 0;
  int replayToken = 0;

  @override
  void initState() {
    super.initState();
    signs = signsFor(widget.category.title);
  }

  bool get isFirst => index == 0;
  bool get isLast => index == signs.length - 1;

  void _go(int delta) {
    setState(() {
      index = (index + delta).clamp(0, signs.length - 1);
      replayToken++; // restart the new sign's tutorial
    });
  }

  Future<void> _finish() async {
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final sign = signs[index];

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ExitButton(onPressed: () => Navigator.pop(context, false)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: (index + 1) / signs.length,
                        minHeight: 10,
                        backgroundColor: primaryColor.withValues(alpha: 0.18),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(primaryColor),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Learn · ${widget.category.title} · '
                        '${index + 1} of ${signs.length}',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey[500]),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Watch, then copy the sign',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF222222),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SignVideoBox(
                        sign: sign,
                        replayToken: replayToken,
                        maxHeight: 300,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        sign.word,
                        style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF222222)),
                      ),
                      const SizedBox(height: 10),
                      HintCard(text: sign.howTo, label: 'HOW TO SIGN'),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: lightBlue,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.back_hand_outlined,
                                size: 18, color: primaryColor),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Your turn: make the sign with your own hand '
                                'before tapping next.',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[700],
                                    height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
              GameButton(
                text: isLast ? 'FINISH LEARNING' : 'NEXT SIGN',
                color: primaryColor,
                shadowColor: primaryShadow,
                icon: isLast ? Icons.check_rounded : null,
                onTap: isLast ? _finish : () => _go(1),
              ),
              const SizedBox(height: 10),
              GameButton(
                text: 'BACK',
                color: Colors.white,
                shadowColor: const Color(0xFFE3E3E3),
                textColor: primaryColor,
                outlined: true,
                borderColor: primaryColor,
                onTap: isFirst ? null : () => _go(-1),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ===============================
// DRAG & DROP QUIZ PAGE (lesson 1.2) — progress is SAVED
// ===============================

class DragDropQuizPage extends StatefulWidget {
  final CategoryData category;
  final String lessonLabel;

  const DragDropQuizPage({
    super.key,
    required this.category,
    required this.lessonLabel,
  });

  @override
  State<DragDropQuizPage> createState() => _DragDropQuizPageState();
}

class _DragDropQuizPageState extends State<DragDropQuizPage> {
  late final List<SignEntry> questions;
  late final List<String> choices;

  int index = 0;
  int correct = 0; // questions answered correctly on the first try
  bool missed = false; // wrong attempt on the current question
  bool showHint = false;
  bool finished = false;
  String? dropped;

  String get cat => widget.category.title;
  String get lesson => widget.lessonLabel;
  SignEntry get current => questions[index];
  bool get answered => dropped != null;
  bool get isCorrect => dropped == current.word;

  @override
  void initState() {
    super.initState();
    final signs = signsFor(cat);
    questions = signs.take(5).toList();
    choices = signs.take(6).map((s) => s.word).toList();

    // Resume saved quiz progress
    final saved = ProgressStore.quizProgress(cat, lesson);
    if (saved != null) {
      final i = saved['index'] as int? ?? 0;
      if (i > 0 && i < questions.length) {
        index = i;
        correct = saved['correct'] as int? ?? 0;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showMessage(context,
              'Resumed at question ${index + 1} of ${questions.length}');
        });
      }
    }
  }

  void _onDrop(String letter) {
    setState(() {
      dropped = letter;
      if (letter != current.word) missed = true;
    });
  }

  void _reset() => setState(() => dropped = null);

  Future<void> _next() async {
    final int newCorrect = correct + (missed ? 0 : 1);

    if (index + 1 >= questions.length) {
      await ProgressStore.saveQuizResult(
          cat, lesson, newCorrect, questions.length);
      await ProgressStore.clearQuizProgress(cat, lesson);
      if (!mounted) return;
      setState(() {
        correct = newCorrect;
        finished = true;
      });
    } else {
      await ProgressStore.saveQuizProgress(
          cat, lesson, index + 1, newCorrect);
      if (!mounted) return;
      setState(() {
        correct = newCorrect;
        index++;
        dropped = null;
        missed = false;
        showHint = false;
      });
    }
  }

  Future<void> _retry() async {
    await ProgressStore.clearQuizProgress(cat, lesson);
    if (!mounted) return;
    setState(() {
      index = 0;
      correct = 0;
      missed = false;
      showHint = false;
      finished = false;
      dropped = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final double progressValue = finished
        ? 1.0
        : (index + (answered && isCorrect ? 1 : 0)) / questions.length;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ExitButton(onPressed: () async {
                    if (!finished && !await confirmExit(context)) return;
                    if (!context.mounted) return;
                    Navigator.pop(context, finished);
                  }),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: progressValue,
                        minHeight: 10,
                        backgroundColor: primaryColor.withValues(alpha: 0.18),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(primaryColor),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: finished ? _buildResults() : _buildQuestion(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults() {
    final bool great = correct >= (questions.length * 0.6).ceil();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(),
        Container(
          width: 140,
          height: 140,
          decoration: BoxDecoration(
            color: lightBlue,
            shape: BoxShape.circle,
            border:
                Border.all(color: primaryColor.withValues(alpha: 0.3), width: 3),
          ),
          child: Icon(
            great ? Icons.emoji_events_rounded : Icons.thumb_up_alt_rounded,
            size: 70,
            color: great ? flameColor : primaryColor,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Quiz complete!',
          style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: Color(0xFF222222)),
        ),
        const SizedBox(height: 8),
        Text(
          'You got $correct of ${questions.length} on the first try.',
          style: TextStyle(fontSize: 15, color: Colors.grey[600]),
        ),
        const SizedBox(height: 6),
        Text(
          'Your result has been saved.',
          style: TextStyle(fontSize: 12, color: Colors.grey[500]),
        ),
        const Spacer(),
        GameButton(
          text: 'FINISH',
          color: primaryColor,
          shadowColor: primaryShadow,
          onTap: () => Navigator.pop(context, true),
        ),
        const SizedBox(height: 12),
        GameButton(
          text: 'RETRY QUIZ',
          color: Colors.white,
          shadowColor: const Color(0xFFE3E3E3),
          textColor: primaryColor,
          outlined: true,
          borderColor: primaryColor,
          onTap: _retry,
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  // The picture shown as the quiz prompt: the real photo(s) when the sign has
  // them, otherwise the placeholder hand icon.
  Widget _buildPrompt() {
    if (current.images.isNotEmpty) {
      return SignVideoBox(sign: current, maxHeight: 230);
    }
    return Center(
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          color: lightBlue,
          shape: BoxShape.circle,
          border:
              Border.all(color: primaryColor.withValues(alpha: 0.3), width: 3),
        ),
        child:
            const Icon(Icons.back_hand_rounded, size: 60, color: primaryColor),
      ),
    );
  }

  Widget _buildQuestion() {
    final Color boxBorder = !answered
        ? primaryColor.withValues(alpha: 0.5)
        : (isCorrect ? correctColor : incorrectColor);

    return SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.of(context).size.height - 170,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Question ${index + 1} of ${questions.length}',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey[500]),
            ),
            const SizedBox(height: 6),
            const Text(
              'Drag and Drop the correct answer',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: Color(0xFF222222),
                height: 1.3,
              ),
            ),
            const SizedBox(height: 18),

            // sign prompt (photo or placeholder)
            _buildPrompt(),
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                onPressed: () => setState(() => showHint = !showHint),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.lightbulb_outline_rounded,
                    size: 16, color: hintAccent),
                label: Text(showHint ? 'Hide hint' : 'Show hint',
                    style: const TextStyle(
                        color: hintAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w800)),
              ),
            ),
            // Hint: amber card, labeled and bold so it doesn't blend in
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: showHint
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: HintCard(text: current.howTo),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            const SizedBox(height: 8),

            // drop zone
            Center(
              child: DragTarget<String>(
                onAcceptWithDetails: (details) => _onDrop(details.data),
                builder: (context, candidate, rejected) {
                  final bool hovering = candidate.isNotEmpty;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 150,
                    height: 50,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: hovering ? lightBlue : Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: boxBorder, width: 2.5),
                    ),
                    child: Text(
                      dropped ?? '',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF222222),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 22),

            // choice tiles
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: choices.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 1.7,
              ),
              itemBuilder: (context, i) => _ChoiceTile(label: choices[i]),
            ),

            const SizedBox(height: 18),
            if (answered)
              Center(
                child: Text(
                  isCorrect
                      ? 'Correct! Great job.'
                      : 'Not quite. Try another tile.',
                  style: TextStyle(
                    color: isCorrect ? correctColor : incorrectColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            const SizedBox(height: 10),
            GameButton(
              text: answered && !isCorrect ? 'TRY AGAIN' : 'CONTINUE',
              color: answered && !isCorrect ? incorrectColor : primaryColor,
              shadowColor: answered && !isCorrect
                  ? const Color(0xFFB4453D)
                  : primaryShadow,
              onTap: !answered ? null : (isCorrect ? _next : _reset),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  final String label;
  const _ChoiceTile({required this.label});

  Widget _tile({double opacity = 1, bool raised = false}) {
    return Opacity(
      opacity: opacity,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: primaryColor.withValues(alpha: 0.45), width: 2),
          boxShadow: raised
              ? [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  )
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: primaryColor,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Draggable<String>(
      data: label,
      feedback: SizedBox(
        width: 100,
        height: 54,
        child: Material(
          color: Colors.transparent,
          child: _tile(raised: true),
        ),
      ),
      childWhenDragging: _tile(opacity: 0.3),
      child: _tile(),
    );
  }
}

// ===============================
// SIGN VIDEO BOX
//
// Shows a sign:
//  - photos (1 or more) -> drawn in a frame with the exact photo ratio
//    (kSignAspect), the whole picture is always visible, nothing is cropped.
//    2+ photos loop automatically like a tiny animation; tap to step.
//  - no photos          -> the placeholder "tap to play" box.
//
// [maxHeight] is the tallest the photo frame may be; the width follows from
// the ratio and never exceeds the available width, so it fits any phone.
// ===============================

class SignVideoBox extends StatefulWidget {
  final SignEntry sign;
  final int replayToken;
  final double maxHeight;

  const SignVideoBox({
    super.key,
    required this.sign,
    this.replayToken = 0,
    this.maxHeight = 260,
  });

  @override
  State<SignVideoBox> createState() => _SignVideoBoxState();
}

class _SignVideoBoxState extends State<SignVideoBox> {
  // placeholder state
  bool playing = false;
  Timer? _timer;

  // photo state
  int frame = 0;
  Timer? _frameTimer;

  List<String> get _images => widget.sign.images;
  bool get _hasPhoto => _images.isNotEmpty;
  bool get _multi => _images.length > 1;

  @override
  void initState() {
    super.initState();
    _startFrames();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precache();
  }

  // Load every frame ahead of time so the loop never flickers.
  void _precache() {
    for (final path in _images) {
      precacheImage(AssetImage(path), context, onError: (e, s) {});
    }
  }

  void _startFrames({bool reset = true}) {
    _frameTimer?.cancel();
    if (reset) frame = 0;
    if (!_multi) return;
    _frameTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (!mounted) return;
      setState(() => frame = (frame + 1) % _images.length);
    });
  }

  void _stepFrame() {
    if (!_multi) return;
    setState(() => frame = (frame + 1) % _images.length);
    _startFrames(reset: false);
  }

  void _play({bool notify = true}) {
    _timer?.cancel();
    if (notify) {
      setState(() => playing = true);
    } else {
      playing = true;
    }
    _timer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => playing = false);
    });
  }

  @override
  void didUpdateWidget(covariant SignVideoBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool signChanged = oldWidget.sign.id != widget.sign.id;
    final bool replay = oldWidget.replayToken != widget.replayToken;

    if (signChanged) {
      _timer?.cancel();
      playing = false;
      _startFrames();
      _precache();
    } else if (replay && _hasPhoto) {
      _startFrames();
    }

    if (replay && !_hasPhoto) {
      _play(notify: false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _frameTimer?.cancel();
    super.dispose();
  }

  Widget _brokenImage(String path) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined,
                size: 40, color: primaryColor),
            if (kDebugMode) ...[
              const SizedBox(height: 6),
              Text(
                path,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: Colors.grey[600]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPhoto() {
    final images = _images;
    final int i = frame % images.length;
    final String? caption =
        (_multi && i < widget.sign.captions.length) ? widget.sign.captions[i] : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double availW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : widget.maxHeight * kSignAspect;
        final double w = min(availW, widget.maxHeight * kSignAspect);
        final double h = w / kSignAspect;

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: _stepFrame,
                child: Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: primaryColor.withValues(alpha: 0.4), width: 2),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset(
                      images[i],
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (c, e, s) => _brokenImage(images[i]),
                    ),
                  ),
                ),
              ),
              if (_multi) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(images.length, (d) {
                    final bool active = d == i;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: active ? 18 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: active
                            ? primaryColor
                            : primaryColor.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: w,
                  child: Text(
                    caption != null
                        ? 'Step ${i + 1} of ${images.length} · $caption'
                        : 'Step ${i + 1} of ${images.length}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey[600],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaceholder() {
    return GestureDetector(
      onTap: _play,
      child: Container(
        width: double.infinity,
        height: 190,
        decoration: BoxDecoration(
          color: primaryColor,
          borderRadius: BorderRadius.circular(20),
          border: Border(bottom: BorderSide(color: primaryShadow, width: 5)),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  playing
                      ? Icons.front_hand_rounded
                      : Icons.play_circle_outline_rounded,
                  size: 72,
                  color: Colors.white,
                ),
                const SizedBox(height: 8),
                Text(
                  playing
                      ? 'Signing "${widget.sign.word}"...'
                      : 'Tap to play',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (playing)
              Positioned(
                left: 16,
                right: 16,
                bottom: 14,
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(widget.replayToken),
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(seconds: 3),
                  builder: (context, value, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: value,
                      minHeight: 5,
                      backgroundColor: Colors.white.withValues(alpha: 0.3),
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _hasPhoto ? _buildPhoto() : _buildPlaceholder();
  }
}

// Small photo used in lists (first photo of the sign, same 3:4 ratio).
class SignThumb extends StatelessWidget {
  final SignEntry sign;
  final double height;
  const SignThumb({super.key, required this.sign, this.height = 64});

  @override
  Widget build(BuildContext context) {
    final double width = height * kSignAspect;
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: lightBlue,
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: primaryColor.withValues(alpha: 0.25), width: 1),
      ),
      child: sign.images.isEmpty
          ? const Icon(Icons.back_hand_rounded, color: primaryColor, size: 22)
          : Image.asset(
              sign.images.first,
              fit: BoxFit.cover,
              cacheWidth: 200,
              errorBuilder: (c, e, s) => const Icon(Icons.back_hand_rounded,
                  color: primaryColor, size: 22),
            ),
    );
  }
}

// ===============================
// HONOR SYSTEM PAGE
// "Review the following hand sign" -> Yes, I got it / Needs Work / Replay Tutorial
// Statuses are SAVED. "Needs Work" signs come back at the end of the deck.
// ===============================

class HonorSystemPage extends StatefulWidget {
  final String title;
  final List<SignEntry> signs;

  const HonorSystemPage({super.key, required this.title, required this.signs});

  @override
  State<HonorSystemPage> createState() => _HonorSystemPageState();
}

class _HonorSystemPageState extends State<HonorSystemPage> {
  late List<SignEntry> queue;
  late final int total;
  int gotCount = 0;
  int replayToken = 0;

  @override
  void initState() {
    super.initState();
    queue = List.of(widget.signs);
    total = queue.length;
  }

  bool get finished => queue.isEmpty;

  Future<void> _answer(bool got) async {
    final sign = queue.first;
    await ProgressStore.setHonor(sign, got);
    if (!mounted) return;
    setState(() {
      queue.removeAt(0);
      if (got) {
        gotCount++;
      } else {
        queue.add(sign); // review again at the end
      }
      replayToken++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ExitButton(onPressed: () async {
                    if (!finished && !await confirmExit(context)) return;
                    if (!context.mounted) return;
                    Navigator.pop(context, finished);
                  }),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: primaryColor,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Text(
                      'Practice',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: gotCount / total,
                  minHeight: 10,
                  backgroundColor: primaryColor.withValues(alpha: 0.18),
                  valueColor: const AlwaysStoppedAnimation<Color>(primaryColor),
                ),
              ),
              const SizedBox(height: 18),
              Expanded(child: finished ? _buildDone() : _buildCard()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard() {
    final sign = queue.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Scrollable content so nothing overflows on small phones
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey[500])),
                const SizedBox(height: 6),
                const Text(
                  'Review the\nfollowing hand sign',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF222222),
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 18),
                SignVideoBox(
                  sign: sign,
                  replayToken: replayToken,
                  maxHeight: 260,
                ),
                const SizedBox(height: 16),
                Text(
                  sign.word,
                  style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF222222)),
                ),
                const SizedBox(height: 8),
                HintCard(text: sign.howTo, label: 'HOW TO SIGN'),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        GameButton(
          text: 'YES, I GOT IT',
          color: primaryColor,
          shadowColor: primaryShadow,
          icon: Icons.check_rounded,
          onTap: () => _answer(true),
        ),
        const SizedBox(height: 10),
        GameButton(
          text: 'NEEDS WORK',
          color: Colors.white,
          shadowColor: const Color(0xFFE3E3E3),
          textColor: incorrectColor,
          outlined: true,
          borderColor: incorrectColor,
          icon: Icons.refresh_rounded,
          onTap: () => _answer(false),
        ),
        const SizedBox(height: 10),
        GameButton(
          text: 'REPLAY TUTORIAL',
          color: Colors.white,
          shadowColor: const Color(0xFFE3E3E3),
          textColor: primaryColor,
          outlined: true,
          borderColor: primaryColor,
          icon: Icons.replay_rounded,
          onTap: () => setState(() => replayToken++),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildDone() {
    return Column(
      children: [
        const Spacer(),
        Container(
          width: 140,
          height: 140,
          decoration: BoxDecoration(
            color: lightBlue,
            shape: BoxShape.circle,
            border:
                Border.all(color: primaryColor.withValues(alpha: 0.3), width: 3),
          ),
          child: const Icon(Icons.emoji_events_rounded,
              size: 70, color: flameColor),
        ),
        const SizedBox(height: 24),
        const Text(
          'Practice complete!',
          style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: Color(0xFF222222)),
        ),
        const SizedBox(height: 8),
        Text(
          'You mastered $gotCount ${gotCount == 1 ? 'sign' : 'signs'}. Saved!',
          style: TextStyle(fontSize: 15, color: Colors.grey[600]),
        ),
        const Spacer(),
        GameButton(
          text: 'DONE',
          color: primaryColor,
          shadowColor: primaryShadow,
          onTap: () => Navigator.pop(context, true),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

// ===============================
// DICTIONARY (tab 0)
// ===============================

class DictionaryView extends StatefulWidget {
  const DictionaryView({super.key});

  @override
  State<DictionaryView> createState() => _DictionaryViewState();
}

class _DictionaryViewState extends State<DictionaryView> {
  final TextEditingController searchController = TextEditingController();
  String query = '';
  String filter = 'All';

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  List<SignEntry> get results {
    final list = allSigns.where((s) {
      final matchesFilter = filter == 'All' || s.category == filter;
      final q = query.trim().toLowerCase();
      final matchesQuery = q.isEmpty ||
          s.word.toLowerCase().contains(q) ||
          s.howTo.toLowerCase().contains(q);
      return matchesFilter && matchesQuery;
    }).toList();
    list.sort((a, b) => a.word.toLowerCase().compareTo(b.word.toLowerCase()));
    return list;
  }

  void _openFilter() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final options = ['All', ...categories.map((c) => c.title)];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Filter by category',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF222222))),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: options.map((o) {
                    final selected = o == filter;
                    return ChoiceChip(
                      label: Text(o),
                      selected: selected,
                      selectedColor: primaryColor,
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : primaryColor,
                        fontWeight: FontWeight.w700,
                      ),
                      backgroundColor: lightBlue,
                      side: BorderSide.none,
                      showCheckmark: false,
                      onSelected: (_) {
                        setState(() => filter = o);
                        Navigator.pop(context);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = results;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton(
                tooltip: 'Filter by category',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.menu_rounded,
                    color: Color(0xFF222222), size: 26),
                onPressed: _openFilter,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  controller: searchController,
                  cursorColor: primaryColor,
                  onChanged: (v) => setState(() => query = v),
                  decoration: InputDecoration(
                    hintText: 'Search a sign',
                    hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13),
                    prefixIcon: const Icon(Icons.search_rounded,
                        color: primaryColor, size: 20),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              searchController.clear();
                              setState(() => query = '');
                            },
                          ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(
                          color: primaryColor.withValues(alpha: 0.4), width: 1.5),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide:
                          const BorderSide(color: primaryColor, width: 2),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              const Text('Dictionary',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF222222))),
              const Spacer(),
              if (filter != 'All')
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: lightBlue,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(filter,
                      style: const TextStyle(
                          color: primaryColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w800)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text('No signs found. Try a different word or category.',
                        style: TextStyle(color: Colors.grey[500])),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: list.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final sign = list[i];
                      return _DictionaryTile(
                        sign: sign,
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => SignDetailPage(sign: sign),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String? status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == null) return const SizedBox.shrink();
    final bool got = status == 'got';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (got ? correctColor : incorrectColor).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        got ? 'Learned' : 'Needs work',
        style: TextStyle(
          color: got ? const Color(0xFF3F9C5D) : incorrectColor,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DictionaryTile extends StatelessWidget {
  final SignEntry sign;
  final VoidCallback onTap;
  const _DictionaryTile({required this.sign, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: primaryColor.withValues(alpha: 0.2), width: 1.5),
        ),
        child: Row(
          children: [
            SignThumb(sign: sign, height: 64),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sign.word,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF222222))),
                  const SizedBox(height: 2),
                  Text(sign.category,
                      style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                ],
              ),
            ),
            _StatusChip(status: ProgressStore.honor(sign)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }
}

// ===============================
// SIGN DETAIL PAGE (dictionary entry)
// ===============================

class SignDetailPage extends StatefulWidget {
  final SignEntry sign;
  const SignDetailPage({super.key, required this.sign});

  @override
  State<SignDetailPage> createState() => _SignDetailPageState();
}

class _SignDetailPageState extends State<SignDetailPage> {
  @override
  Widget build(BuildContext context) {
    final sign = widget.sign;
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExitButton(onPressed: () => Navigator.pop(context)),
              const SizedBox(height: 6),
              // Scrollable so the photo + text never overflow on small phones
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Dictionary',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF888888))),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(sign.word,
                                style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF222222))),
                          ),
                          _StatusChip(status: ProgressStore.honor(sign)),
                        ],
                      ),
                      Text(sign.category,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[500])),
                      const SizedBox(height: 18),
                      HintCard(text: sign.howTo, label: 'HOW TO SIGN'),
                      const SizedBox(height: 18),
                      SignVideoBox(sign: sign, maxHeight: 300),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
              GameButton(
                text: 'PRACTICE THIS SIGN',
                color: primaryColor,
                shadowColor: primaryShadow,
                icon: Icons.touch_app_rounded,
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => HonorSystemPage(
                        title: 'Dictionary · ${sign.word}',
                        signs: [sign],
                      ),
                    ),
                  );
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

// ===============================
// PRACTICE (tab 2) — honor system hub
// ===============================

class PracticeView extends StatelessWidget {
  final VoidCallback onChanged;
  const PracticeView({super.key, required this.onChanged});

  Future<void> _startPractice(
      BuildContext context, String title, List<SignEntry> signs) async {
    // practice signs that are not mastered yet; if all mastered, review all
    var deck = signs.where((s) => !ProgressStore.isMastered(s)).toList();
    if (deck.isEmpty) deck = List.of(signs);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => HonorSystemPage(title: title, signs: deck),
      ),
    );
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final mastered = allSigns.where(ProgressStore.isMastered).length;
    final needsWork =
        allSigns.where((s) => ProgressStore.honor(s) == 'needs').length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 20),
        children: [
          const Text('Practice',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF222222))),
          const SizedBox(height: 4),
          Text('Honor system: watch, sign it yourself, then rate yourself.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _StatBox(
                    value: '$mastered',
                    label: 'Learned',
                    color: correctColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatBox(
                    value: '$needsWork',
                    label: 'Needs work',
                    color: incorrectColor),
              ),
            ],
          ),
          const SizedBox(height: 16),
          GameButton(
            text: 'START PRACTICE',
            color: primaryColor,
            shadowColor: primaryShadow,
            icon: Icons.play_arrow_rounded,
            onTap: () => _startPractice(context, 'All signs', allSigns),
          ),
          const SizedBox(height: 18),
          const Text('By category',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF222222))),
          const SizedBox(height: 10),
          ...categories.map((c) {
            final signs = signsFor(c.title);
            final got = signs.where(ProgressStore.isMastered).length;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                onTap: () => _startPractice(context, c.title, signs),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: primaryColor.withValues(alpha: 0.2), width: 1.5),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: lightBlue,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(c.icon, color: primaryColor, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.title,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF222222))),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                value: got / signs.length,
                                minHeight: 6,
                                backgroundColor:
                                    primaryColor.withValues(alpha: 0.15),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                    primaryColor),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text('$got/${signs.length}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.grey[600])),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  const _StatBox(
      {required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w900, color: color)),
          Text(label,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}