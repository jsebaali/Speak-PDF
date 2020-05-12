//
//  ViewControllerDoc.h
//  Demo 1.1
//
//  Created by Jana Sebaali on 4/20/20.
//  Copyright © 2020 Jana Sebaali. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <PDFNet/PDFNet.h>
#import <Tools/Tools.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <Speech/Speech.h>

NS_ASSUME_NONNULL_BEGIN

@interface ViewControllerDoc : UIViewController
<UITextFieldDelegate, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate, PTPDFViewCtrlToolDelegate>


    @property (weak, nonatomic) IBOutlet UITextField *pdfURL;
    @property SFSpeechRecognizer *speechRecognizer;
    @property SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
    @property SFSpeechRecognitionTask *recognitionTask;
    @property AVAudioEngine *audioEngine;
    @property PTPDFViewCtrl *pdfViewCtrl;
       - (void)startListening;
       - (IBAction)continueButton2:(id)sender;

@end



NS_ASSUME_NONNULL_END
