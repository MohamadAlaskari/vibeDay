import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:fresh_dio/fresh_dio.dart';
import 'package:vibe_day/data/api/api_service.dart';
import 'package:vibe_day/data/repository/auth_data_repository.dart';
import 'package:vibe_day/data/repository/user_storage_repository.dart';
import 'package:vibe_day/domain/model/auth_result.dart';
import 'package:vibe_day/domain/model/user.dart';
import 'package:vibe_day/domain/model/activity.dart';
import 'package:vibe_day/domain/model/user_preferences.dart';
import 'package:vibe_day/domain/model/health_data.dart';

class VibeDayRepository {
  late final ApiService _client;
  final AuthDataRepository _tokenStorageRepository;
  final UserStorageRepository _userStorageRepository;
  final String _baseUrl;
  late Dio _dio;
  late final Fresh _fresh;
  final _controller = StreamController<AuthResult>();

  VibeDayRepository({
    required AuthDataRepository tokenStorageRepository,
    required String baseUrl,
    required UserStorageRepository userStorageRepository,
  }) : _baseUrl = baseUrl,
       _userStorageRepository = userStorageRepository,
       _tokenStorageRepository = tokenStorageRepository {
    _init();
  }

  Stream<AuthResult> get status async* {
    final token = await _fresh.token;
    if (token != null) {
      final user = await _userStorageRepository.getUser();
      if (user != null) {
        yield AuthResult.authenticated(user);
      }
    }
    yield* _controller.stream;
  }

  Future<List<dynamic>> getWeeklyWeather(String location) async {
    try {
      final token = await getToken();

      if (token == null) {
        throw Exception('Authentication required. Please login again.');
      }

      final authHeader = 'Bearer ${token.accessToken}';

      final response = await _dio.get(
        '/weather/week/location',
        queryParameters: {'location': location},
        options: Options(
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': authHeader,
          },
        ),
      );

      if (response.data is List) {
        return response.data as List<dynamic>;
      } else {
        throw Exception('Unexpected response format for weather data');
      }
    } catch (e) {
      log('Error fetching weather data: $e');

      if (e is DioException) {
        log('DioException details:');
        log('- Status Code: ${e.response?.statusCode}');
        log('- Request URL: ${e.requestOptions.uri}');
        log('- Request Headers: ${e.requestOptions.headers}');
        log('- Response Data: ${e.response?.data}');

        if (e.response?.statusCode == 401) {
          log('401 error - forcing logout');
          await logout();
          throw Exception('Session expired. Please login again.');
        }
      }

      rethrow;
    }
  }

  Future<AuthResult> login(String email, String password) async {
    AuthResult status;
    try {
      final response = await _dio.post(
        '/auth/login',
        data: {'email': email, 'password': password},
        options: Options(headers: {'Accept': 'application/json'}),
      );

      final accessToken = response.data['accessToken'];

      if (accessToken == null) {
        log('Error: Token not found in response: ${response.data}');
        return AuthResult.unauthenticated(401, 'Token not found in response');
      }

      OAuth2Token token = OAuth2Token(
        accessToken: accessToken,
        refreshToken: accessToken,
        tokenType: 'Bearer',
      );
      await setToken(token);

      try {
        final userResponse = await Dio().get(
          '${_dio.options.baseUrl}/auth/current-user',
          options: Options(
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Accept': 'application/json',
            },
          ),
        );

        log('User response: ${userResponse.data}');
        final user = User.fromJson(userResponse.data);
        status = AuthResult.authenticated(user);
        await _userStorageRepository.saveUser(user);
      } catch (userError) {
        log('Error fetching user details: $userError');
        status = AuthResult.unauthenticated(
          500,
          'Failed to fetch user details: $userError',
        );
      }
    } on DioException catch (e) {
      String errorMessage = 'DioException: ';

      if (e.response != null) {
        errorMessage += 'Status ${e.response!.statusCode}: ${e.response!.data}';
        log(errorMessage);
        status = AuthResult.unauthenticated(
          e.response!.statusCode,
          errorMessage,
        );
      } else {
        log(errorMessage);
        status = AuthResult.unauthenticated(500, errorMessage);
      }
    } catch (e) {
      log('Unexpected error during login: $e');
      status = AuthResult.unauthenticated(500, e.toString());
    }
    _controller.add(status);
    return status;
  }

  Future<AuthResult> register({
    required String email,
    required String firstName,
    required String lastName,
    required String password,
    required String username,
  }) async {
    AuthResult status;
    try {
      final response = await _dio.post(
        '/auth/register',
        data: {
          'email': email,
          'firstName': firstName,
          'lastName': lastName,
          'username': username,
          'password': password,
        },
        options: Options(headers: {'Accept': 'application/json'}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        log('Registration successful: ${response.data}');

        final accessToken = response.data['accessToken'];

        if (accessToken != null) {
          status = const AuthResult.unauthenticated(
            200,
            'Registration successful. Please verify your email and log in.',
          );
        } else {
          status = const AuthResult.unauthenticated(
            200,
            'Registration successful. Please log in.',
          );
        }
      } else {
        status = AuthResult.unauthenticated(
          response.statusCode,
          'Registration failed',
        );
      }
    } on DioException catch (e) {
      if (e.response != null) {
        final statusCode = e.response!.statusCode;
        final responseData = e.response!.data;

        if ((statusCode == 200 || statusCode == 201) && responseData != null) {
          log('Registration successful despite DioException: $responseData');
          status = const AuthResult.unauthenticated(
            200,
            'Registration successful. Please verify your email and log in.',
          );
        } else if (statusCode == 400 && responseData != null) {
          final errorMessage = responseData.toString();

          if (errorMessage.contains(
            'password must be longer than or equal to 6 characters',
          )) {
            status = const AuthResult.unauthenticated(
              400,
              'PASSWORD_TOO_SHORT',
            );
          } else {
            log('Validation error during registration: $errorMessage');
            status = AuthResult.unauthenticated(
              statusCode,
              'Validation error: $errorMessage',
            );
          }
        } else if (statusCode == 500 && responseData != null) {
          final errorMessage = responseData.toString();

          if (errorMessage.contains('Duplicate entry') &&
              errorMessage.contains('IDX_97672ac88f789774dd47f7c8be')) {
            status = const AuthResult.unauthenticated(
              500,
              'EMAIL_ALREADY_EXISTS',
            );
          } else if (errorMessage.contains('Duplicate entry') &&
              errorMessage.contains('IDX_fe0bb3f6520ee0469504521e71')) {
            status = const AuthResult.unauthenticated(
              500,
              'USERNAME_ALREADY_EXISTS',
            );
          } else {
            log('Server error during registration: $errorMessage');
            status = AuthResult.unauthenticated(
              statusCode,
              'Registration failed: Server error',
            );
          }
        } else {
          log(
            'HTTP error during registration: Status $statusCode: $responseData',
          );
          status = AuthResult.unauthenticated(
            statusCode,
            'Registration failed',
          );
        }
      } else {
        log('Network error during registration: ${e.message}');
        status = AuthResult.unauthenticated(500, 'Network error');
      }
    } catch (e) {
      log('Unexpected error during registration: $e');
      status = AuthResult.unauthenticated(500, e.toString());
    }
    _controller.add(status);
    return status;
  }

  Future<void> requestPasswordReset(String email) async {
    try {
      final response = await _dio.post(
        '/auth/request-reset',
        data: {'email': email},
        options: Options(headers: {'Accept': 'application/json'}),
      );

      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception('Failed to send reset email');
      }

      log('Password reset email sent successfully: ${response.data}');
    } on DioException catch (e) {
      if (e.response != null) {
        final statusCode = e.response!.statusCode;
        final responseData = e.response!.data;

        if (statusCode == 404 &&
            responseData is Map &&
            responseData['error']?['message'] == 'User not found') {
          throw Exception('Status 404: User not found');
        }

        String errorMessage = 'Status $statusCode: $responseData';
        log('Failed to send reset email: $errorMessage');
        throw Exception(errorMessage);
      } else {
        String errorMessage = e.message ?? 'Unknown network error';
        log('Network error during password reset request: $errorMessage');
        throw Exception(errorMessage);
      }
    } catch (e) {
      log('Unexpected error during password reset request: $e');
      rethrow;
    }
  }

  Future<List<Activity>> getSuggestions({
    required double latitude,
    required double longitude,
    required String date,
  }) async {
    try {
      final token = await getToken();

      if (token == null) {
        throw Exception('Authentication required. Please login again.');
      }

      final response = await _client.getSuggestions(latitude, longitude, date);

      log('Suggestions API Response: $response');

      if (response is! List) {
        log('Unexpected response format: ${response.runtimeType}');
        return [];
      }

      return response.whereType<Map<String, dynamic>>().map((suggestion) {
        final processedSuggestion = Map<String, dynamic>.from(suggestion);

        processedSuggestion['healthDataMatch'] =
            suggestion['healthDataMatch'] ?? false;

        final reasonField = suggestion['healthDataMatchReason'];
        List<String> reasons = [];

        try {
          if (reasonField is List) {
            reasons = reasonField.map((item) => item.toString()).toList();
          } else if (reasonField is String) {
            if (reasonField.trim().isNotEmpty) {
              if (reasonField.contains(',')) {
                reasons =
                    reasonField
                        .split(',')
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                        .toList();
              } else {
                reasons = [reasonField.trim()];
              }
            }
          }
        } catch (e) {
          log(
            'Error parsing healthDataMatchReason for ${suggestion['title']}: $e',
          );
        }

        processedSuggestion['healthDataMatchReason'] = reasons;

        if (processedSuggestion['healthDataMatch'] == true) {
          final reasons =
              processedSuggestion['healthDataMatchReason'] as List<String>;
          log('Health match for ${processedSuggestion['title']}: $reasons');
        }

        return Activity.fromJson(processedSuggestion);
      }).toList();
    } catch (e) {
      log('Error fetching suggestions: $e');

      if (e is DioException) {
        if (e.response?.statusCode == 401) {
          log('401 error - forcing logout');
          await logout();
          throw Exception('Session expired. Please login again.');
        }
      }

      return [];
    }
  }

  Future<UserPreferences> createUserPreferences({
    required UserPreferences preferences,
  }) async {
    try {
      final token = await getToken();

      if (token == null) {
        throw Exception('Authentication required. Please login again.');
      }

      final response = await _client.createUserPreferences(
        preferences.toApiRequest(),
      );

      log('Create User Preferences API Response: $response');

      return UserPreferences(
        selectedVibes: _toStringList(response['selectedVibes']) ?? [],
        selectedLifeVibes: _toStringList(response['selectedLifeVibes']) ?? [],
        selectedExperienceTypes:
            _toStringList(response['selectedExperienceTypes']) ?? [],
        budget: _toDouble(response['budget']) ?? 0.0,
        distanceRadius: _toDouble(response['distanceRadius']) ?? 0.0,
        selectedTimeWindows:
            _toStringList(response['selectedTimeWindows']) ?? [],
        selectedGroupSizes: _toStringList(response['selectedGroupSizes']) ?? [],
      );
    } catch (e) {
      log('Error creating user preferences: $e');

      if (e is DioException && e.response?.statusCode == 401) {
        await logout();
        throw Exception('Session expired. Please login again.');
      }

      rethrow;
    }
  }

  Future<UserPreferences?> getUserPreferences() async {
    try {
      final token = await getToken();

      if (token == null) {
        throw Exception('Authentication required. Please login again.');
      }

      final response = await _client.getUserPreferences();

      log('Get User Preferences API Response: $response');

      if (response is Map<String, dynamic>) {
        Map<String, dynamic> preferencesData;

        if (response['status'] == 'empty') {
          log(
            'User preferences not found - returning null for empty preferences',
          );
          return null;
        } else if (response['status'] == 'success' &&
            response['data'] != null) {
          preferencesData = Map<String, dynamic>.from(response['data']);
        } else if (response['data'] != null) {
          preferencesData = Map<String, dynamic>.from(response['data']);
        } else if (response['selectedVibes'] != null) {
          preferencesData = Map<String, dynamic>.from(response);
        } else {
          log('Unexpected response format: $response');
          return null;
        }

        preferencesData['budget'] = _toDouble(preferencesData['budget']) ?? 0.0;
        preferencesData['distanceRadius'] =
            _toDouble(preferencesData['distanceRadius']) ?? 0.0;

        preferencesData['selectedVibes'] =
            _toStringList(preferencesData['selectedVibes']) ?? [];
        preferencesData['selectedLifeVibes'] =
            _toStringList(preferencesData['selectedLifeVibes']) ?? [];
        preferencesData['selectedExperienceTypes'] =
            _toStringList(preferencesData['selectedExperienceTypes']) ?? [];
        preferencesData['selectedTimeWindows'] =
            _toStringList(preferencesData['selectedTimeWindows']) ?? [];
        preferencesData['selectedGroupSizes'] =
            _toStringList(preferencesData['selectedGroupSizes']) ?? [];

        return UserPreferences(
          selectedVibes: _toStringList(preferencesData['selectedVibes']) ?? [],
          selectedLifeVibes:
              _toStringList(preferencesData['selectedLifeVibes']) ?? [],
          selectedExperienceTypes:
              _toStringList(preferencesData['selectedExperienceTypes']) ?? [],
          budget: _toDouble(preferencesData['budget']) ?? 0.0,
          distanceRadius: _toDouble(preferencesData['distanceRadius']) ?? 0.0,
          selectedTimeWindows:
              _toStringList(preferencesData['selectedTimeWindows']) ?? [],
          selectedGroupSizes:
              _toStringList(preferencesData['selectedGroupSizes']) ?? [],
        );
      }

      log('Unexpected response format: $response');
      return null;
    } catch (e) {
      log('Error getting user preferences: $e');

      if (e is DioException) {
        if (e.response?.statusCode == 401) {
          await logout();
          throw Exception('Session expired. Please login again.');
        }
        if (e.response?.statusCode == 404) {
          log('User preferences not found - returning null');
          return null;
        }
      }

      rethrow;
    }
  }

  Future<UserPreferences> updateUserPreferences({
    required UserPreferences preferences,
  }) async {
    try {
      final token = await getToken();

      if (token == null) {
        throw Exception('Authentication required. Please login again.');
      }

      final response = await _client.updateUserPreferences(
        preferences.toApiRequest(),
      );

      log('Update User Preferences API Response: $response');

      return UserPreferences(
        selectedVibes: _toStringList(response['selectedVibes']) ?? [],
        selectedLifeVibes: _toStringList(response['selectedLifeVibes']) ?? [],
        selectedExperienceTypes:
            _toStringList(response['selectedExperienceTypes']) ?? [],
        budget: _toDouble(response['budget']) ?? 0.0,
        distanceRadius: _toDouble(response['distanceRadius']) ?? 0.0,
        selectedTimeWindows:
            _toStringList(response['selectedTimeWindows']) ?? [],
        selectedGroupSizes: _toStringList(response['selectedGroupSizes']) ?? [],
      );
    } catch (e) {
      log('Error updating user preferences: $e');

      if (e is DioException && e.response?.statusCode == 401) {
        await logout();
        throw Exception('Session expired. Please login again.');
      }

      rethrow;
    }
  }

  Future<HealthData> submitHealthData({required HealthData healthData}) async {
    try {
      final token = await getToken();

      if (token == null) {
        throw Exception('Authentication required. Please login again.');
      }

      final apiData = healthData.toApiJson();
      final response = await _client.submitHealthData(apiData);

      log('Submit Health Data API Response: $response');
      final result = HealthData.fromApiResponse(response);

      return result;
    } catch (e) {
      log('Error submitting health data: $e');

      if (e is DioException && e.response?.statusCode == 401) {
        await logout();
        throw Exception('Session expired. Please login again.');
      }

      rethrow;
    }
  }

  Future<List<HealthData>> getHealthData() async {
    try {
      final token = await getToken();

      if (token == null) {
        throw Exception('Authentication required. Please login again.');
      }

      final response = await _client.getHealthData();

      log('Get Health Data API Response: $response');

      if (response is List) {
        return response
            .whereType<Map<String, dynamic>>()
            .map((healthDataJson) => HealthData.fromApiResponse(healthDataJson))
            .toList();
      }

      return [];
    } catch (e) {
      log('Error getting health data: $e');

      if (e is DioException && e.response?.statusCode == 401) {
        await logout();
        throw Exception('Session expired. Please login again.');
      }

      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getRawHealthData() async {
    try {
      final token = await getToken();

      if (token == null) {
        throw Exception('Authentication required. Please login again.');
      }

      final response = await _client.getHealthData();

      log('Get Raw Health Data API Response: $response');

      if (response is List) {
        return response.whereType<Map<String, dynamic>>().toList();
      }

      return [];
    } catch (e) {
      log('Error getting raw health data: $e');

      if (e is DioException && e.response?.statusCode == 401) {
        await logout();
        throw Exception('Session expired. Please login again.');
      }

      return [];
    }
  }

  Future<void> logout() async {
    await _fresh.setToken(null);
    await _userStorageRepository.deleteUser();
    _controller.add(const AuthResult.unauthenticated(403, 'logged out'));
  }

  Future<OAuth2Token?> getToken() async => await _fresh.token;

  Future<void> setToken(OAuth2Token? token) async {
    await _fresh.setToken(token);
  }

  void dispose() {
    _controller.close();
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  List<String>? _toStringList(dynamic value) {
    if (value == null) return null;
    if (value is List) {
      return value.map((item) => item.toString()).toList();
    }
    return null;
  }

  Future<void> _init() async {
    _dio = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        contentType: 'application/json',
        headers: {'Accept': 'application/json'},
        validateStatus: (status) {
          return status! < 400;
        },
        followRedirects: false,
      ),
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          return handler.next(options);
        },
        onResponse: (response, handler) async {
          if (response.statusCode == 303) {
            var location = response.headers.value(HttpHeaders.locationHeader);
            var res = await _dio.get(location!);
            return handler.resolve(res);
          }
          return handler.next(response);
        },
        onError: (error, handler) async {
          if (error.response?.statusCode == 401 ||
              error.response?.statusCode == 403) {}
          return handler.next(error);
        },
      ),
    );

    _fresh = Fresh.oAuth2(
      tokenStorage: _tokenStorageRepository,
      refreshToken: (token, client) async {
        log(
          'Token refresh requested, but no refresh endpoint available - forcing logout',
        );
        await logout();
        throw DioException(
          requestOptions: RequestOptions(path: ''),
          type: DioExceptionType.badResponse,
          message: 'Token expired - please login again',
        );
      },
      tokenHeader: (token) {
        log(
          'Fresh: tokenHeader called with token: ${token.accessToken.substring(0, 10)}...',
        );
        return {HttpHeaders.authorizationHeader: 'Bearer ${token.accessToken}'};
      },
      shouldRefresh: (response) {
        log(
          'Fresh: shouldRefresh called, status: ${response?.statusCode}, but refresh disabled',
        );
        return false;
      },
    );

    _dio.interceptors.add(_fresh);

    _client = ApiService(_dio, baseUrl: _baseUrl);
    final token = await _fresh.token;
    if (token != null) {
      final user = await _userStorageRepository.getUser();
      if (user != null) {
        _controller.add(AuthResult.authenticated(user));
      } else {
        await logout();
      }
    } else {
      _controller.add(const AuthResult.unauthenticated(null, null));
    }
  }
}
