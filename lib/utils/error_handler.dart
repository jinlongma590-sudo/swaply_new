// lib/utils/error_handler.dart - Unified error handling
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:swaply/utils/logger.dart';

/// Error types
enum ErrorType {
  network, // Network error
  auth, // Authentication error
  validation, // Validation error
  business, // Business logic error
  system, // System error
  unknown, // Unknown error
}

/// App-level exception
class AppException implements Exception {
  final String message;
  final ErrorType type;
  final String? code;
  final Map<String, dynamic>? details;
  final StackTrace? stackTrace;

  AppException({
    required this.message,
    required this.type,
    this.code,
    this.details,
    this.stackTrace,
  });

  factory AppException.network(String message, {String? code}) =>
      AppException(message: message, type: ErrorType.network, code: code);

  factory AppException.auth(String message, {String? code}) =>
      AppException(message: message, type: ErrorType.auth, code: code);

  factory AppException.validation(String message, {String? code}) =>
      AppException(message: message, type: ErrorType.validation, code: code);

  factory AppException.business(String message,
      {String? code, Map<String, dynamic>? details}) =>
      AppException(
          message: message,
          type: ErrorType.business,
          code: code,
          details: details);

  factory AppException.system(String message,
      {String? code, StackTrace? stackTrace}) =>
      AppException(
          message: message,
          type: ErrorType.system,
          code: code,
          stackTrace: stackTrace);

  @override
  String toString() =>
      'AppException(type: $type, message: $message, code: $code)';
}

/// Global error handler
class ErrorHandler {
  static final ErrorHandler _instance = ErrorHandler._internal();
  factory ErrorHandler() => _instance;
  ErrorHandler._internal();

  /// Handle any error and normalize to AppException
  static AppException handleError(dynamic error, {StackTrace? stackTrace}) {
    AppLogger.error('Handle exception', error: error, stackTrace: stackTrace);

    if (error is AppException) return error;
    if (error is AuthException) return _handleAuthException(error);
    if (error is PostgrestException) return _handlePostgrestException(error);
    if (error is StorageException) return _handleStorageException(error);

    // Other errors
    return AppException.system(
      _getGenericErrorMessage(error),
      stackTrace: stackTrace,
    );
  }

  /// Auth exceptions
  static AppException _handleAuthException(AuthException error) {
    final code = error.statusCode;
    final msg = error.message.toLowerCase();

    String message;
    switch (msg) {
      case 'invalid login credentials':
        message = 'Invalid credentials. Please check your email and password.';
        break;
      case 'email not confirmed':
        message = 'Please verify your email before logging in.';
        break;
      case 'signup disabled':
        message = 'Sign up is currently disabled. Please try again later.';
        break;
      case 'user not found':
        message = 'User not found.';
        break;
      case 'weak password':
        message = 'Password is too weak. Please use a stronger password.';
        break;
      case 'email already exists':
        message = 'This email is already registered.';
        break;
      default:
        message = 'Authentication failed: ${error.message}';
    }
    return AppException.auth(message, code: code);
  }

  /// PostgREST / database exceptions
  static AppException _handlePostgrestException(PostgrestException error) {
    final code = error.code;
    String message;
    switch (code) {
      case '23505': // unique violation
        message = error.message.contains('duplicate key')
            ? 'Data already exists. Please avoid duplicate actions.'
            : 'Data conflict. Please retry.';
        break;
      case '23503': // foreign key violation
        message = 'Related data not found. Operation failed.';
        break;
      case '42501': // insufficient privilege
        message = 'Insufficient permissions for this operation.';
        break;
      case 'PGRST116': // row level security
        message = 'Access denied by security policy.';
        break;
      default:
        message = 'Database operation failed: ${error.message}';
    }
    return AppException.business(message, code: code);
  }

  /// Storage exceptions
  static AppException _handleStorageException(StorageException error) {
    final code = error.statusCode;
    final msg = error.message.toLowerCase();

    String message;
    switch (msg) {
      case 'bucket not found':
        message = 'Storage bucket not found.';
        break;
      case 'object not found':
        message = 'File not found.';
        break;
      case 'upload failed':
        message = 'File upload failed. Please try again.';
        break;
      case 'file too large':
        message = 'File is too large. Please choose a smaller file.';
        break;
      default:
        message = 'File operation failed: ${error.message}';
    }
    return AppException.system(message, code: code);
  }

  /// Fallback messages for common errors
  static String _getGenericErrorMessage(dynamic error) {
    final s = error.toString();
    if (s.contains('SocketException')) return 'Network connection failed.';
    if (s.contains('TimeoutException')) return 'Operation timed out.';
    if (s.contains('FormatException')) return 'Invalid data format.';
    return 'System error. Please try again later.';
  }

  /// Show error in UI
  static void showError(BuildContext context, dynamic error,
      {VoidCallback? onRetry}) {
    final appError = handleError(error);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: _buildErrorSnackBar(appError),
        backgroundColor: _getErrorColor(appError.type),
        behavior: SnackBarBehavior.floating,
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.r)),
        margin: EdgeInsets.all(16.r),
        duration: Duration(seconds: appError.type == ErrorType.system ? 5 : 3),
        action: onRetry != null
            ? SnackBarAction(
          label: 'Retry',
          textColor: Colors.white,
          onPressed: onRetry,
        )
            : null,
      ),
    );
  }

  /// Build snackbar content
  static Widget _buildErrorSnackBar(AppException error) {
    return Row(
      children: [
        Icon(_getErrorIcon(error.type), color: Colors.white, size: 20.r),
        SizedBox(width: 12.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _getErrorTitle(error.type),
                style: TextStyle(
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w600,
                    color: Colors.white),
              ),
              Text(
                error.message,
                style: TextStyle(
                  fontSize: 12.sp,
                  // Flutter 3.19.x: use withOpacity instead of withValues
                  color: Colors.white.withOpacity(0.9),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static Color _getErrorColor(ErrorType type) {
    switch (type) {
      case ErrorType.network:
        return Colors.orange[600]!;
      case ErrorType.auth:
        return Colors.red[600]!;
      case ErrorType.validation:
        return Colors.amber[600]!;
      case ErrorType.business:
        return Colors.blue[600]!;
      case ErrorType.system:
        return Colors.red[700]!;
      case ErrorType.unknown:
        return Colors.grey[600]!;
    }
  }

  static IconData _getErrorIcon(ErrorType type) {
    switch (type) {
      case ErrorType.network:
        return Icons.wifi_off;
      case ErrorType.auth:
        return Icons.lock;
      case ErrorType.validation:
        return Icons.warning;
      case ErrorType.business:
        return Icons.info;
      case ErrorType.system:
        return Icons.error;
      case ErrorType.unknown:
        return Icons.help;
    }
  }

  static String _getErrorTitle(ErrorType type) {
    switch (type) {
      case ErrorType.network:
        return 'Network Error';
      case ErrorType.auth:
        return 'Authentication Error';
      case ErrorType.validation:
        return 'Input Error';
      case ErrorType.business:
        return 'Business Error';
      case ErrorType.system:
        return 'System Error';
      case ErrorType.unknown:
        return 'Unknown Error';
    }
  }
}
