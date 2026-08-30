<?php
header("Content-Type: application/json");
date_default_timezone_set('Asia/Manila');
require_once 'db_config.php';
require_once 'auto_backup_checker.php';
require_once 'email_config.php';

use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require 'PHPMailer/Exception.php';
require 'PHPMailer/PHPMailer.php';
require 'PHPMailer/SMTP.php';

// Suppress errors/warnings from breaking JSON output
error_reporting(0);
ini_set('display_errors', 0);

function log_access($conn, $user_id, $username, $action) {
    $ip = $_SERVER['REMOTE_ADDR'];
    $stmt = $conn->prepare("INSERT INTO access_logs (user_id, username, action, ip_address) VALUES (?, ?, ?, ?)");
    $stmt->execute([$user_id, $username, $action, $ip]);
}

// Trigger auto-backup check on login
if (function_exists('check_and_perform_auto_backup')) {
    check_and_perform_auto_backup($conn);
}

$data = json_decode(file_get_contents("php://input"));
$identifier = "";
$password = "";

if ($data && !empty($data->username_or_email)) {
    $identifier = $data->username_or_email;
    $password = $data->password;
} elseif (isset($_POST['username_or_email'])) {
    $identifier = $_POST['username_or_email'];
    $password = $_POST['password'];
}

if (!empty($identifier) && !empty($password)) {
    try {
        // 1. Search sa 'users' table (Admin/Driver)
        $query = "SELECT user_id, username, name, email, phone, license_number, preferred_truck, role, password_hash, is_archived, two_factor_enabled FROM users WHERE username = ? OR email = ?";
        $stmt = $conn->prepare($query);
        $stmt->execute([$identifier, $identifier]);
        $user = $stmt->fetch(PDO::FETCH_ASSOC);

        if ($user && password_verify($password, $user['password_hash'])) {
            if ($user['is_archived'] == 1) {
                log_access($conn, $user['user_id'], $user['username'], "Login Attempt (Archived Account)");
                $msg = ($user['role'] === 'driver')
                    ? "Your driver account is pending approval. Please wait for an administrator to activate it."
                    : "Your account has been archived. Please contact the administrator.";
                echo json_encode(["success" => false, "message" => $msg]);
                exit;
            }

            if ($user['two_factor_enabled'] == 1) {
                // Generate OTP for 2FA
                $otp = sprintf("%06d", mt_rand(1, 999999));
                $expiry = date("Y-m-d H:i:s", strtotime("+5 minutes"));

                $conn->prepare("DELETE FROM password_resets WHERE email = ?")->execute([$user['email']]);
                $conn->prepare("INSERT INTO password_resets (email, token, expiry) VALUES (?, ?, ?)")->execute([$user['email'], $otp, $expiry]);

                // Send Email
                $mail = new PHPMailer(true);
                try {
                    $mail->isSMTP();
                    $mail->Host       = SMTP_HOST;
                    $mail->SMTPAuth   = true;
                    $mail->Username   = SMTP_USER;
                    $mail->Password   = SMTP_PASS;
                    $mail->SMTPSecure = PHPMailer::ENCRYPTION_STARTTLS;
                    $mail->Port       = SMTP_PORT;
                    $mail->setFrom(SMTP_FROM, SMTP_NAME);
                    $mail->addAddress($user['email']);
                    $mail->isHTML(true);
                    $mail->Subject = 'Your 2FA Verification Code - Garbage Tracker';
                    $mail->Body    = "
                        <div style='font-family: Arial, sans-serif; padding: 20px; border: 1px solid #ddd;'>
                            <h2 style='color: #2e7d32;'>Security Verification</h2>
                            <p>Hello <strong>{$user['name']}</strong>,</p>
                            <p>Your verification code is:</p>
                            <div style='background: #f1f8e9; padding: 15px; font-size: 28px; font-weight: bold; text-align: center; letter-spacing: 10px; color: #2e7d32;'>
                                $otp
                            </div>
                            <p>This code will expire in 5 minutes.</p>
                        </div>
                    ";
                    $mail->send();
                } catch (Exception $e) {}

                log_access($conn, $user['user_id'], $user['username'], "2FA Required");
                unset($user['password_hash']);
                echo json_encode([
                    "success" => true,
                    "message" => "2FA_REQUIRED",
                    "user" => $user
                ]);
                exit;
            }

            log_access($conn, $user['user_id'], $user['username'], "Successful Login");
            unset($user['password_hash']);
            unset($user['is_archived']);
            echo json_encode(["success" => true, "message" => "Login successful", "user" => $user]);
            exit;
        }

        // 2. Search sa 'residents' table
        $query = "SELECT resident_id as user_id, username, name, email, phone, purok, complete_address, 'resident' as role, password_hash, is_archived FROM residents WHERE username = ? OR email = ?";
        $stmt = $conn->prepare($query);
        $stmt->execute([$identifier, $identifier]);
        $resident = $stmt->fetch(PDO::FETCH_ASSOC);

        if ($resident && password_verify($password, $resident['password_hash'])) {
            if ($resident['is_archived'] == 1) {
                echo json_encode(["success" => false, "message" => "Account pending approval"]);
                exit;
            }
            log_access($conn, $resident['user_id'], $resident['username'], "Successful Login (Resident)");
            unset($resident['password_hash']);
            echo json_encode(["success" => true, "message" => "Login successful", "user" => $resident]);
            exit;
        }

        echo json_encode(["success" => false, "message" => "Invalid username/email or password"]);
    } catch (PDOException $e) {
        echo json_encode(["success" => false, "message" => "Database Error"]);
    }
} else {
    echo json_encode(["success" => false, "message" => "Incomplete data"]);
}
?>