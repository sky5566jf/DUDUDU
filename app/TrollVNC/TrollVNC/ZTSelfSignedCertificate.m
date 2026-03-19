/*
 This file is part of MatisuVNC
 Copyright (c) 2025 Matisu <Matisu@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import "ZTSelfSignedCertificate.h"
#import <Security/Security.h>

#pragma mark - 绉佹湁 Security 绗﹀彿澹版槑

// 绉佹湁鍑芥暟锛堝湪 SecCertificateRequest.c 涓疄鐜帮級
extern SecCertificateRef SecGenerateSelfSignedCertificate(CFArrayRef subject, CFDictionaryRef __nullable parameters,
                                                          SecKeyRef publicKey, SecKeyRef privateKey);

// 鍚勭绉佹湁甯搁噺锛堝湪 Security 绉佹湁澶翠腑瀹氫箟锛?extern const CFStringRef kSecOidCommonName;
extern const CFStringRef kSecCSRBasicContraintsPathLen;
extern const CFStringRef kSecCertificateKeyUsage;
extern const CFStringRef kSecCertificateExtensionsEncoded;

// keyUsage bit 瀹氫箟锛堝榻?SecCertificatePriv.h锛?enum {
    kSecKeyUsageUnspecified = 0,
    kSecKeyUsageDigitalSignature = 1 << 0,
    kSecKeyUsageNonRepudiation = 1 << 1,
    kSecKeyUsageKeyEncipherment = 1 << 2,
    kSecKeyUsageDataEncipherment = 1 << 3,
    kSecKeyUsageKeyAgreement = 1 << 4,
    kSecKeyUsageKeyCertSign = 1 << 5,
    kSecKeyUsageCRLSign = 1 << 6,
    kSecKeyUsageEncipherOnly = 1 << 7,
    kSecKeyUsageDecipherOnly = 1 << 8,
    kSecKeyUsageAll = 0x7FF
};

#pragma mark - Helper: DER 鈫?PEM

static NSString *ZTPEMFromDER(NSData *der, NSString *header, NSString *footer) {
    if (!der)
        return nil;

    NSString *b64 = [der base64EncodedStringWithOptions:0];
    NSMutableString *pem = [NSMutableString string];

    [pem appendFormat:@"-----BEGIN %@-----\n", header];

    const NSUInteger lineLen = 64;
    for (NSUInteger i = 0; i < b64.length; i += lineLen) {
        NSUInteger len = MIN(lineLen, b64.length - i);
        NSString *line = [b64 substringWithRange:NSMakeRange(i, len)];
        [pem appendFormat:@"%@\n", line];
    }

    [pem appendFormat:@"-----END %@-----\n", footer];
    return pem;
}

/// 鎵嬪伐鏋勯€?EKU = { serverAuth, clientAuth } 鐨?DER
/// ExtendedKeyUsage ::= SEQUENCE OF OBJECT IDENTIFIER
///   serverAuth 1.3.6.1.5.5.7.3.1
///   clientAuth 1.3.6.1.5.5.7.3.2
static NSData *ZTExtendedKeyUsageDER(void) {
    // 30 14       SEQUENCE, length 0x14
    //    06 08    OBJECT IDENTIFIER, length 8
    //       2b 06 01 05 05 07 03 01   (1.3.6.1.5.5.7.3.1)
    //    06 08    OBJECT IDENTIFIER, length 8
    //       2b 06 01 05 05 07 03 02   (1.3.6.1.5.5.7.3.2)
    static const uint8_t ekuBytes[] = {0x30, 0x14, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03,
                                       0x01, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02};
    return [NSData dataWithBytes:ekuBytes length:sizeof(ekuBytes)];
}

#pragma mark - 瀹炵幇

@interface ZTSelfSignedCertificate ()
@property(nonatomic, readwrite) NSString *certificatePEM;
@property(nonatomic, readwrite) NSString *privateKeyPEM;
@end

@implementation ZTSelfSignedCertificate

+ (instancetype)generateWithCommonName:(NSString *)commonName {
    ZTSelfSignedCertificate *obj = [[self alloc] init];
    if (![obj _generateWithCommonName:commonName]) {
        return nil;
    }
    return obj;
}

- (BOOL)_generateWithCommonName:(NSString *)commonName {
    OSStatus status = errSecSuccess;

    SecKeyRef publicKey = NULL;
    SecKeyRef privateKey = NULL;
    SecCertificateRef cert = NULL;

    CFMutableDictionaryRef certParams = NULL;
    CFMutableDictionaryRef encodedExts = NULL;

    CFArrayRef subject = NULL;
    CFArrayRef cnPair = NULL;
    CFArrayRef cnRDN = NULL;

    CFStringRef cfCommonName = (__bridge CFStringRef)commonName;

    // 1. 鐢熸垚 RSA key pair (2048 bit)
    {
        CFMutableDictionaryRef keyParams = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (!keyParams)
            goto cleanup;

        CFDictionaryAddValue(keyParams, kSecAttrKeyType, kSecAttrKeyTypeRSA);

        int keySize = 2048;
        CFNumberRef keySizeNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keySize);
        CFDictionaryAddValue(keyParams, kSecAttrKeySizeInBits, keySizeNum);
        CFRelease(keySizeNum);

        CFDictionaryAddValue(keyParams, kSecAttrLabel, cfCommonName);

        status = SecKeyGeneratePair(keyParams, &publicKey, &privateKey);
        CFRelease(keyParams);

        if (status != errSecSuccess || !publicKey || !privateKey) {
            goto cleanup;
        }
    }

    // 2. 鏋勯€?certParams锛欳A:TRUE, pathLen=0, keyUsage, EKU(serverAuth+clientAuth)
    certParams = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    if (!certParams)
        goto cleanup;

    // 2.1 basicConstraints: pathLen = 0 => CA:TRUE, pathLen=0
    {
        CFIndex pathLenValue = 0;
        CFNumberRef pathLen = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &pathLenValue);
        CFDictionarySetValue(certParams, kSecCSRBasicContraintsPathLen, pathLen);
        CFRelease(pathLen);
    }

    // 2.2 keyUsage锛氭帴杩?minica root 鐨勯鏍硷紝鍏佽绛惧彂璇佷功 + CRL + 涓€浜涘父鐢ㄧ敤閫?    {
        int keyUsageValue =
            kSecKeyUsageDigitalSignature | kSecKeyUsageKeyEncipherment | kSecKeyUsageKeyCertSign | kSecKeyUsageCRLSign;

        CFNumberRef keyUsageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keyUsageValue);

        CFDictionarySetValue(certParams, kSecCertificateKeyUsage, keyUsageNum);
        CFRelease(keyUsageNum);
    }

    // 2.3 Extended Key Usage: serverAuth + clientAuth
    //    浣跨敤 kSecCertificateExtensionsEncoded锛岃嚜宸辨彁渚?DER 缂栧ソ鐨?EKU
    {
        encodedExts = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
        if (!encodedExts)
            goto cleanup;

        NSData *ekuDER = ZTExtendedKeyUsageDER();
        CFDataRef ekuData = CFDataCreate(kCFAllocatorDefault, ekuDER.bytes, (CFIndex)ekuDER.length);
        if (!ekuData)
            goto cleanup;

        // OID "2.5.29.37" = id-ce-extKeyUsage
        CFDictionarySetValue(encodedExts, CFSTR("2.5.29.37"), ekuData);
        CFRelease(ekuData);

        CFDictionarySetValue(certParams, kSecCertificateExtensionsEncoded, encodedExts);
    }

    // 3. 鏋勯€?subject锛堜笁灞傛暟缁勭粨鏋勶紝鍙湁涓€涓?CN锛岀被浼?minica root 鐨?Subject锛?    {
        // 绗笁灞傦細[ kSecOidCommonName, cfCommonName ]
        const void *cnFields[2] = {kSecOidCommonName, cfCommonName};
        cnPair = CFArrayCreate(kCFAllocatorDefault, cnFields, 2, &kCFTypeArrayCallBacks);
        if (!cnPair)
            goto cleanup;

        // 绗簩灞傦細[ cnPair ]
        const void *cnRDNFields[1] = {cnPair};
        cnRDN = CFArrayCreate(kCFAllocatorDefault, cnRDNFields, 1, &kCFTypeArrayCallBacks);
        if (!cnRDN)
            goto cleanup;

        // 椤跺眰锛歔 cnRDN ]
        const void *rdnList[1] = {cnRDN};
        subject = CFArrayCreate(kCFAllocatorDefault, rdnList, 1, &kCFTypeArrayCallBacks);
        if (!subject)
            goto cleanup;
    }

    // 4. 璋冪敤 SecGenerateSelfSignedCertificate 鐢熸垚鑷 CA 璇佷功
    cert = SecGenerateSelfSignedCertificate(subject, certParams, publicKey, privateKey);

    if (!cert) {
        goto cleanup;
    }

    // 5. 瀵煎嚭 certificate (DER 鈫?PEM)
    {
        CFDataRef certData = SecCertificateCopyData(cert);
        if (!certData)
            goto cleanup;

        NSData *derCert = (__bridge_transfer NSData *)certData;
        NSString *pem = ZTPEMFromDER(derCert, @"CERTIFICATE", @"CERTIFICATE");
        if (!pem)
            goto cleanup;

        self.certificatePEM = pem;
    }

    // 6. 瀵煎嚭 private key (DER 鈫?PEM, PKCS#1 RSA PRIVATE KEY)
    {
        CFErrorRef error = NULL;
        CFDataRef keyData = SecKeyCopyExternalRepresentation(privateKey, &error);
        if (!keyData) {
            if (error)
                CFRelease(error);
            goto cleanup;
        }

        NSData *derKey = (__bridge_transfer NSData *)keyData;
        NSString *pem = ZTPEMFromDER(derKey, @"RSA PRIVATE KEY", @"RSA PRIVATE KEY");
        if (!pem)
            goto cleanup;

        self.privateKeyPEM = pem;
    }

cleanup:
    if (cert)
        CFRelease(cert);
    if (publicKey)
        CFRelease(publicKey);
    if (privateKey)
        CFRelease(privateKey);

    if (subject)
        CFRelease(subject);
    if (cnRDN)
        CFRelease(cnRDN);
    if (cnPair)
        CFRelease(cnPair);

    if (encodedExts)
        CFRelease(encodedExts);
    if (certParams)
        CFRelease(certParams);

    return (self.certificatePEM != nil && self.privateKeyPEM != nil);
}

@end
