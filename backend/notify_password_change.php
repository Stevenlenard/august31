<?php
use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require 'PHPMailer/src/Exception.php';
require 'PHPMailer/src/PHPMailer.php';
require 'PHPMailer/src/SMTP.php';
require_once 'email_config.php';

function send_password_change_notification($email) {
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
        $mail->addAddress($email);

        $mail->isHTML(true);
        $mail->Subject = 'Security Notice: Password Changed Successfully';

        $mail->Body = "
            <div style='font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e0e0e0; borderRadius: 10px;'>
                <h2 style='color: #00796B;'>Password Reset Successful</h2>
                <p>Hello,</p>
                <p>This is an automated notification to confirm that your account password has been successfully reset.</p>
                <p><b>If you performed this action,</b> you can safely ignore this email.</p>
                <p style='background-color: #FFF3E0; padding: 15px; borderRadius: 5px; borderLeft: 5px solid #FF9800;'>
                    <strong>Notice:</strong> If you did not request this change, please contact our support team immediately to secure your account.
                </p>
                <p>Thank you,<br>Brgy. Balintawak Garbage Tracker Team</p>
                <hr style='border: 0; borderTop: 1px solid #eeeeee; margin: 20px 0;'>
                <p style='font-size: 12px; color: #777777;'>&copy; 2026 Brgy. Balintawak Lipa City. All rights reserved.</p>
            </div>
        ";

        $mail->send();
        return true;
    } catch (Exception $e) {
        error_log(\"Email Notification Error: {$mail->ErrorInfo}\");
        return false;
    }
}
?>
