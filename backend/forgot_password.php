<?php
header("Content-Type: application/json");
date_default_timezone_set('Asia/Manila'); // Set to local timezone
require_once 'db_config.php';
require_once 'email_config.php';

// PHPMailer Includes
use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\SMTP;
use PHPMailer\PHPMailer\Exception;

require 'PHPMailer/Exception.php';
require 'PHPMailer/PHPMailer.php';
require 'PHPMailer/SMTP.php';

$data = json_decode(file_get_contents("php://input"));

if (!$data || empty($data->email)) {
    echo json_encode(["success" => false, "message" => "Email is required"]);
    exit;
}

$email = $data->email;

try {
    // 1. Check if email exists
    $query = "SELECT email FROM users WHERE email = ? UNION SELECT email FROM residents WHERE email = ?";
    $stmt = $conn->prepare($query);
    $stmt->execute([$email, $email]);
    $user = $stmt->fetch();

    if (!$user) {
        echo json_encode(["success" => false, "message" => "Email address not found"]);
        exit;
    }

    // 2. Generate 6-digit OTP
    $otp = sprintf("%06d", mt_rand(1, 999999));
    $expiry = date("Y-m-d H:i:s", strtotime("+3 minutes"));

    // 3. Save to password_resets table
    $deleteStmt = $conn->prepare("DELETE FROM password_resets WHERE email = ?");
    $deleteStmt->execute([$email]);

    $insertStmt = $conn->prepare("INSERT INTO password_resets (email, token, expiry) VALUES (?, ?, ?)");
    $insertStmt->execute([$email, $otp, $expiry]);

    // 4. Send Email using PHPMailer
    $mail = new PHPMailer(true);

    try {
        // SMTP Server settings
        $mail->isSMTP();
        $mail->Host       = SMTP_HOST;
        $mail->SMTPAuth   = true;
        $mail->Username   = SMTP_USER;
        $mail->Password   = SMTP_PASS;
        $mail->SMTPSecure = PHPMailer::ENCRYPTION_STARTTLS;
        $mail->Port       = SMTP_PORT;

        // Recipients
        $mail->setFrom(SMTP_FROM, SMTP_NAME);
        $mail->addAddress($email);

        // Content
        $mail->isHTML(true);
        $mail->Subject = 'Reset Your Password - Garbage Tracker';
        $mail->Body    = "
            <div style='font-family: Arial, sans-serif; padding: 20px; border: 1px solid #ddd;'>
                <h2 style='color: #2c3e50;'>Password Reset Request</h2>
                <p>Hello,</p>
                <p>We received a request to reset your password for the <strong>Garbage Tracker</strong> app.</p>
                <p>Your verification code is:</p>
                <div style='background: #f4f4f4; padding: 15px; font-size: 24px; font-weight: bold; text-align: center; letter-spacing: 5px; color: #e74c3c;'>
                    $otp
                </div>
                <p>This code will expire in <strong>3 minutes</strong>. If you did not request this, please ignore this email.</p>
                <hr style='border: 0; border-top: 1px solid #eee;'>
                <p style='font-size: 12px; color: #7f8c8d;'>This is an automated message, please do not reply.</p>
            </div>
        ";

        $mail->send();
        echo json_encode(["success" => true, "message" => "OTP sent to your email"]);

    } catch (Exception $e) {
        echo json_encode([
            "success" => false,
            "message" => "Email could not be sent. Mailer Error: {$mail->ErrorInfo}"
        ]);
    }

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>