/*
     File: AVCamViewController.m
 Abstract: View controller for camera interface.
  Version: 3.1
 
 Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
 Inc. ("Apple") in consideration of your agreement to the following
 terms, and your use, installation, modification or redistribution of
 this Apple software constitutes acceptance of these terms.  If you do
 not agree with these terms, please do not use, install, modify or
 redistribute this Apple software.
 
 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Inc. may
 be used to endorse or promote products derived from the Apple Software
 without specific prior written permission from Apple.  Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.
 
 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
 
 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 
 Copyright (C) 2014 Apple Inc. All Rights Reserved.
 
 */

#import <MessageUI/MessageUI.h>

#import "AVCamViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>

#import "AVCamPreviewView.h"

static void * CapturingStillImageContext = &CapturingStillImageContext;
static void * RecordingContext = &RecordingContext;
static void * SessionRunningAndDeviceAuthorizedContext = &SessionRunningAndDeviceAuthorizedContext;

@interface AVCamViewController () <AVCaptureFileOutputRecordingDelegate, MFMailComposeViewControllerDelegate>

// For use in the storyboards.
@property (nonatomic, weak) IBOutlet AVCamPreviewView *previewView;
@property (nonatomic, weak) IBOutlet UIButton *recordButton;
@property (nonatomic, weak) IBOutlet UIButton *cameraButton;
@property (nonatomic, weak) IBOutlet UIButton *stillButton;

- (IBAction)toggleMovieRecording:(id)sender;
- (IBAction)changeCamera:(id)sender;
- (IBAction)snapStillImage:(id)sender;
- (IBAction)focusAndExposeTap:(UIGestureRecognizer *)gestureRecognizer;

// Session management.
@property (nonatomic) dispatch_queue_t sessionQueue; // Communicate with the session and other session objects on this queue.
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (nonatomic) AVCaptureMovieFileOutput *movieFileOutput;
@property (nonatomic) AVCaptureStillImageOutput *stillImageOutput;
@property (nonatomic) NSURL *outputFileURL;

// Utilities.
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID;
@property (nonatomic, getter = isDeviceAuthorized) BOOL deviceAuthorized;
@property (nonatomic, readonly, getter = isSessionRunningAndDeviceAuthorized) BOOL sessionRunningAndDeviceAuthorized;
@property (nonatomic) BOOL lockInterfaceRotation;
@property (nonatomic) id runtimeErrorHandlingObserver;

@end

@implementation AVCamViewController

// Thanks to http://stackoverflow.com/questions/29607943/how-to-compress-a-video-to-accurate-size-in-objective-c
- (void)convertVideoToLowQuailtyWithInputURL: (NSURL*)inputURL outputURL: (NSURL*)outputURL handler: (void (^)(AVAssetExportSession*))handler {
  [[NSFileManager defaultManager] removeItemAtURL: outputURL error: nil];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL: inputURL options: nil];

  AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset: asset
                                                                         presetName: AVAssetExportPresetMediumQuality];
  exportSession.outputURL = outputURL;
  exportSession.outputFileType = AVFileTypeQuickTimeMovie;
  [exportSession exportAsynchronouslyWithCompletionHandler: ^(void) { handler(exportSession); }];
}


// not in use
-(void)resizeVideoFrom: (NSURL *)src to: (NSURL *)dst {
  NSError *error = nil;

  AVAssetWriter *videoWriter = [[AVAssetWriter alloc] initWithURL: dst
                                                         fileType: AVFileTypeQuickTimeMovie
                                                            error: &error];
  NSParameterAssert(videoWriter);

  AVAsset *avAsset = [[AVURLAsset alloc] initWithURL: src
                                             options: nil];

  NSDictionary *videoCleanApertureSettings = @{ AVVideoCleanApertureWidthKey: @1080,
                                                AVVideoCleanApertureHeightKey: @1920,
                                                AVVideoCleanApertureHorizontalOffsetKey: @10,
                                                AVVideoCleanApertureVerticalOffsetKey: @10 };
  NSDictionary *codecSettings              = @{ AVVideoAverageBitRateKey: @1960000,
                                                AVVideoMaxKeyFrameIntervalKey: @24,
                                                AVVideoCleanApertureKey: videoCleanApertureSettings };
  NSDictionary *videoCompressionSettings   = @{ AVVideoCodecKey: AVVideoCodecH264,
                                                AVVideoCompressionPropertiesKey: codecSettings,
                                                AVVideoWidthKey: @360,
                                                AVVideoHeightKey: @640 };
  AVAssetWriterInput *videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType: AVMediaTypeVideo
                                                                            outputSettings: videoCompressionSettings];

  NSParameterAssert(videoWriterInput);
  NSParameterAssert([videoWriter canAddInput: videoWriterInput]);

  videoWriterInput.expectsMediaDataInRealTime = NO;  // YES
  [videoWriter addInput: videoWriterInput];

  NSError *aerror = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset: avAsset
                                                         error: &aerror];
  AVAssetTrack *videoTrack = [[avAsset tracksWithMediaType: AVMediaTypeVideo] objectAtIndex: 0];

  videoWriterInput.transform = videoTrack.preferredTransform;

  NSDictionary *videoOptions = @{ (id)kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithInt: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] };
  AVAssetReaderTrackOutput *asset_reader_output = [[AVAssetReaderTrackOutput alloc] initWithTrack: videoTrack
                                                                                   outputSettings: videoOptions];
  [reader addOutput: asset_reader_output];

  //audio setup
  AVAssetWriterInput* audioWriterInput = [AVAssetWriterInput
                                          assetWriterInputWithMediaType: AVMediaTypeAudio
                                          outputSettings: nil];


  AVAssetReader *audioReader = [AVAssetReader assetReaderWithAsset: avAsset
                                                             error: &error];
  AVAssetTrack* audioTrack = [[avAsset tracksWithMediaType: AVMediaTypeAudio] objectAtIndex: 0];
  AVAssetReaderOutput *readerOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack: audioTrack
                                                                                 outputSettings: nil];
  [audioReader addOutput: readerOutput];
  NSParameterAssert(audioWriterInput);
  NSParameterAssert([videoWriter canAddInput: audioWriterInput]);
  audioWriterInput.expectsMediaDataInRealTime = NO;
  [videoWriter addInput: audioWriterInput];

  [videoWriter startWriting];
  [videoWriter startSessionAtSourceTime: kCMTimeZero];
  [reader startReading];
  dispatch_queue_t _processingQueue = dispatch_queue_create("assetAudioWriterQueue", NULL);
  [videoWriterInput requestMediaDataWhenReadyOnQueue: _processingQueue
                                          usingBlock:
   ^{
     while ([videoWriterInput isReadyForMoreMediaData]) {
       CMSampleBufferRef sampleBuffer;
       if ([reader status] == AVAssetReaderStatusReading) {
         if(![videoWriterInput isReadyForMoreMediaData])
           continue;
         sampleBuffer = [asset_reader_output copyNextSampleBuffer];
         // NSLog(@"READING");
         if(sampleBuffer)
           [videoWriterInput appendSampleBuffer:sampleBuffer];
         // NSLog(@"WRITTING...");
       }
       else {
         [videoWriterInput markAsFinished];
         switch ([reader status]) {
           case AVAssetReaderStatusReading:
             // the reader has more for other tracks, even if this one is done
             break;
           case AVAssetReaderStatusCompleted:
             // your method for when the conversion is done
             // should call finishWriting on the writer
             //hook up audio track
           {
             NSString *path = dst.path;
             NSData *data = [[NSFileManager defaultManager] contentsAtPath: path];
             NSLog(@"size after compress video is %u", (unsigned)data.length);
             [videoWriter startSessionAtSourceTime: kCMTimeZero];
             break;
           }
           case AVAssetReaderStatusFailed:
           {
             [videoWriter cancelWriting];
             break;
           }
           default:
             break;
         }
         break;
       }
     }
/*
     // begin
     while ([videoWriterInput isReadyForMoreMediaData]) {

       CMSampleBufferRef sampleBuffer;
       if ([reader status] == AVAssetReaderStatusReading && (sampleBuffer = [asset_reader_output copyNextSampleBuffer])) {
         BOOL result = [videoWriterInput appendSampleBuffer: sampleBuffer];
         CFRelease(sampleBuffer);

         if (!result) {
           // PROBLEM SEEMS TO BE HERE... result is getting false value....
           [reader cancelReading];
           NSLog(@"NO RESULT");
           NSLog(@"videoWriter.error: %@", videoWriter.error);
           break;
         }
       }
       else {
         [videoWriterInput markAsFinished];

         switch ([reader status]) {
           case AVAssetReaderStatusReading:
             // the reader has more for other tracks, even if this one is done
             break;

           case AVAssetReaderStatusCompleted:
             // your method for when the conversion is done
             // should call finishWriting on the writer
             //hook up audio track
             [audioReader startReading];
             [videoWriter startSessionAtSourceTime: kCMTimeZero];
             // dispatch_queue_t mediaInputQueue = dispatch_queue_create("mediaInputQueue", NULL);
             // [audioWriterInput requestMediaDataWhenReadyOnQueue:mediaInputQueue usingBlock:^
             //{
             NSLog(@"Request");
             NSLog(@"Asset Writer ready :%d", audioWriterInput.readyForMoreMediaData);
             while (audioWriterInput.readyForMoreMediaData) {
               CMSampleBufferRef nextBuffer;
               if ([audioReader status] == AVAssetReaderStatusReading && (nextBuffer = [readerOutput copyNextSampleBuffer])) {
                 NSLog(@"Ready");
                 if (nextBuffer) {
                   NSLog(@"NextBuffer");
                   [audioWriterInput appendSampleBuffer: nextBuffer];
                 }
               }
               else {
                 [audioWriterInput markAsFinished];
                 switch ([audioReader status]) {
                   case AVAssetReaderStatusCompleted:
                     [videoWriter finishWriting];
                     NSLog(@"setting  final... the URL");
                     // self.finalURL = [[NSURL alloc] initFileURLWithPath: newName];  // ADD finalURL to self!!
                     break;
                 }
               }
             }
             break;

           case AVAssetReaderStatusFailed:
             [videoWriter cancelWriting];
             break;
         }
         break;
       }
     }
     // end
 */
   }
   ];
  NSLog(@"Write Ended");
}


- (BOOL)isSessionRunningAndDeviceAuthorized
{
	return [[self session] isRunning] && [self isDeviceAuthorized];
}

+ (NSSet *)keyPathsForValuesAffectingSessionRunningAndDeviceAuthorized
{
	return [NSSet setWithObjects:@"session.running", @"deviceAuthorized", nil];
}

- (void)viewDidLoad
{
	[super viewDidLoad];


  NSString *outputFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent: [@"movie" stringByAppendingPathExtension: @"mov"]];
  self.outputFileURL = [NSURL fileURLWithPath: outputFilePath];

	// Create the AVCaptureSession
	AVCaptureSession *session = [[AVCaptureSession alloc] init];
	[self setSession:session];
	
	// Setup the preview view
	[[self previewView] setSession:session];
	
	// Check for device authorization
	[self checkDeviceAuthorizationStatus];
	
	// In general it is not safe to mutate an AVCaptureSession or any of its inputs, outputs, or connections from multiple threads at the same time.
	// Why not do all of this on the main queue?
	// -[AVCaptureSession startRunning] is a blocking call which can take a long time. We dispatch session setup to the sessionQueue so that the main queue isn't blocked (which keeps the UI responsive).
	
	dispatch_queue_t sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
	[self setSessionQueue:sessionQueue];
	
	dispatch_async(sessionQueue, ^{
		[self setBackgroundRecordingID:UIBackgroundTaskInvalid];
		
		NSError *error = nil;
		
		AVCaptureDevice *videoDevice = [AVCamViewController deviceWithMediaType: AVMediaTypeVideo preferringPosition: AVCaptureDevicePositionFront];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
		
		if (error)
		{
			NSLog(@"%@", error);
		}
		
		if ([session canAddInput:videoDeviceInput])
		{
			[session addInput:videoDeviceInput];
			[self setVideoDeviceInput:videoDeviceInput];

			dispatch_async(dispatch_get_main_queue(), ^{
				// Why are we dispatching this to the main queue?
				// Because AVCaptureVideoPreviewLayer is the backing layer for AVCamPreviewView and UIView can only be manipulated on main thread.
				// Note: As an exception to the above rule, it is not necessary to serialize video orientation changes on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
  
				[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)[self interfaceOrientation]];
			});

		}
		
		AVCaptureDevice *audioDevice = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio] firstObject];
		AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
		
		if (error)
		{
			NSLog(@"%@", error);
		}
		
		if ([session canAddInput:audioDeviceInput])
		{
			[session addInput:audioDeviceInput];
		}
		
		AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
		if ([session canAddOutput:movieFileOutput])
		{
			[session addOutput:movieFileOutput];
			AVCaptureConnection *connection = [movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
			if ([connection isVideoStabilizationSupported])
				[connection setEnablesVideoStabilizationWhenAvailable:YES];
			[self setMovieFileOutput:movieFileOutput];
		}
		
		AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
		if ([session canAddOutput:stillImageOutput])
		{
			[stillImageOutput setOutputSettings:@{AVVideoCodecKey : AVVideoCodecJPEG}];
			[session addOutput:stillImageOutput];
			[self setStillImageOutput:stillImageOutput];
		}
	});
}

- (void)viewWillAppear:(BOOL)animated
{
	dispatch_async([self sessionQueue], ^{
		[self addObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:SessionRunningAndDeviceAuthorizedContext];
		[self addObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:CapturingStillImageContext];
		[self addObserver:self forKeyPath:@"movieFileOutput.recording" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:RecordingContext];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
		
		__weak AVCamViewController *weakSelf = self;
		[self setRuntimeErrorHandlingObserver:[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:[self session] queue:nil usingBlock:^(NSNotification *note) {
			AVCamViewController *strongSelf = weakSelf;
			dispatch_async([strongSelf sessionQueue], ^{
				// Manually restarting the session since it must have been stopped due to an error.
				[[strongSelf session] startRunning];
				[[strongSelf recordButton] setTitle:NSLocalizedString(@"Record", @"Recording button record title") forState:UIControlStateNormal];
			});
		}]];
		[[self session] startRunning];
	});
}

- (void)viewDidDisappear:(BOOL)animated
{
	dispatch_async([self sessionQueue], ^{
		[[self session] stopRunning];
		
		[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
		[[NSNotificationCenter defaultCenter] removeObserver:[self runtimeErrorHandlingObserver]];
		
		[self removeObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" context:SessionRunningAndDeviceAuthorizedContext];
		[self removeObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" context:CapturingStillImageContext];
		[self removeObserver:self forKeyPath:@"movieFileOutput.recording" context:RecordingContext];
	});
}

- (BOOL)prefersStatusBarHidden
{
	return YES;
}

- (BOOL)shouldAutorotate
{
	// Disable autorotation of the interface when recording is in progress.
	return ![self lockInterfaceRotation];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
	return UIInterfaceOrientationMaskAll;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
	[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)toInterfaceOrientation];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context == CapturingStillImageContext)
	{
		BOOL isCapturingStillImage = [change[NSKeyValueChangeNewKey] boolValue];
		
		if (isCapturingStillImage)
		{
			[self runStillImageCaptureAnimation];
		}
	}
	else if (context == RecordingContext)
	{
		BOOL isRecording = [change[NSKeyValueChangeNewKey] boolValue];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			if (isRecording)
			{
				[[self cameraButton] setEnabled:NO];
				[[self recordButton] setTitle:NSLocalizedString(@"Stop", @"Recording button stop title") forState:UIControlStateNormal];
				[[self recordButton] setEnabled:YES];
			}
			else
			{
				[[self cameraButton] setEnabled:YES];
				[[self recordButton] setTitle:NSLocalizedString(@"Record", @"Recording button record title") forState:UIControlStateNormal];
				[[self recordButton] setEnabled:YES];
			}
		});
	}
	else if (context == SessionRunningAndDeviceAuthorizedContext)
	{
		BOOL isRunning = [change[NSKeyValueChangeNewKey] boolValue];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			if (isRunning)
			{
				[[self cameraButton] setEnabled:YES];
				[[self recordButton] setEnabled:YES];
				[[self stillButton] setEnabled:YES];
			}
			else
			{
				[[self cameraButton] setEnabled:NO];
				[[self recordButton] setEnabled:NO];
				[[self stillButton] setEnabled:NO];
			}
		});
	}
	else
	{
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

#pragma mark Actions

- (IBAction)toggleMovieRecording:(id)sender
{
	[[self recordButton] setEnabled:NO];
	
	dispatch_async([self sessionQueue], ^{
		if (![[self movieFileOutput] isRecording])
		{
			[self setLockInterfaceRotation:YES];
			
			if ([[UIDevice currentDevice] isMultitaskingSupported])
			{
				// Setup background task. This is needed because the captureOutput:didFinishRecordingToOutputFileAtURL: callback is not received until AVCam returns to the foreground unless you request background execution time. This also ensures that there will be time to write the file to the assets library when AVCam is backgrounded. To conclude this background execution, -endBackgroundTask is called in -recorder:recordingDidFinishToOutputFileURL:error: after the recorded file has been saved.
				[self setBackgroundRecordingID:[[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil]];
			}
			
			// Update the orientation on the movie file output video connection before starting recording.
			[[[self movieFileOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
			
			// Turning OFF flash for video recording
			[AVCamViewController setFlashMode:AVCaptureFlashModeOff forDevice:[[self videoDeviceInput] device]];
			
			// Start recording to a temporary file.
			// NSString *outputFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"movie" stringByAppendingPathExtension:@"mov"]];
      [[self movieFileOutput] startRecordingToOutputFileURL: self.outputFileURL
                                          recordingDelegate: self];
		}
		else
		{
			[[self movieFileOutput] stopRecording];
		}
	});
}

- (IBAction)changeCamera:(id)sender
{
	[[self cameraButton] setEnabled:NO];
	[[self recordButton] setEnabled:NO];
	[[self stillButton] setEnabled:NO];
	
	dispatch_async([self sessionQueue], ^{
		AVCaptureDevice *currentVideoDevice = [[self videoDeviceInput] device];
		AVCaptureDevicePosition preferredPosition = AVCaptureDevicePositionUnspecified;
		AVCaptureDevicePosition currentPosition = [currentVideoDevice position];
		
		switch (currentPosition)
		{
			case AVCaptureDevicePositionUnspecified:
				preferredPosition = AVCaptureDevicePositionBack;
				break;
			case AVCaptureDevicePositionBack:
				preferredPosition = AVCaptureDevicePositionFront;
				break;
			case AVCaptureDevicePositionFront:
				preferredPosition = AVCaptureDevicePositionBack;
				break;
		}
		
		AVCaptureDevice *videoDevice = [AVCamViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:preferredPosition];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];
		
		[[self session] beginConfiguration];
		
		[[self session] removeInput:[self videoDeviceInput]];
		if ([[self session] canAddInput:videoDeviceInput])
		{
			[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];
			
			[AVCamViewController setFlashMode:AVCaptureFlashModeAuto forDevice:videoDevice];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:videoDevice];
			
			[[self session] addInput:videoDeviceInput];
			[self setVideoDeviceInput:videoDeviceInput];
		}
		else
		{
			[[self session] addInput:[self videoDeviceInput]];
		}
		
		[[self session] commitConfiguration];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			[[self cameraButton] setEnabled:YES];
			[[self recordButton] setEnabled:YES];
			[[self stillButton] setEnabled:YES];
		});
	});
}

- (IBAction)snapStillImage: (id)sender {
//	dispatch_async([self sessionQueue], ^{
//		// Update the orientation on the still image output video connection before capturing.
//		[[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
//
//		// Flash set to Auto for Still Capture
//		[AVCamViewController setFlashMode:AVCaptureFlashModeAuto forDevice:[[self videoDeviceInput] device]];
//
//		// Capture a still image.
//		[[self stillImageOutput] captureStillImageAsynchronouslyFromConnection:[[self stillImageOutput] connectionWithMediaType:AVMediaTypeVideo] completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
//
//			if (imageDataSampleBuffer)
//			{
//				NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
//				UIImage *image = [[UIImage alloc] initWithData:imageData];
//				[[[ALAssetsLibrary alloc] init] writeImageToSavedPhotosAlbum:[image CGImage] orientation:(ALAssetOrientation)[image imageOrientation] completionBlock:nil];
//			}
//		}];
//	});

  // Email Subject
  NSString *emailTitle = @"Article 9";
  // Email Content
  NSString *messageBody = @"Thank you for sending your video message. -- Article 9 Project";
  // To address
  NSArray *toRecipents = [NSArray arrayWithObject: @"article9japan@gmail.com"];

  MFMailComposeViewController *mc = [[MFMailComposeViewController alloc] init];
  mc.mailComposeDelegate = self;
  [mc setSubject: emailTitle];
  [mc setMessageBody: messageBody isHTML: NO];
  [mc setToRecipients: toRecipents];

  NSString *pathy = self.outputFileURL.path;
  NSString *newName = [pathy stringByAppendingString: @"_compressed.mov"];
  NSURL *newURL = [NSURL fileURLWithPath: newName];

  // [self resizeVideoFrom: self.outputFileURL to: newURL];

  [self convertVideoToLowQuailtyWithInputURL: self.outputFileURL
                                   outputURL: newURL
                                     handler: ^(AVAssetExportSession *exportSession) {
                                       if (exportSession.status == AVAssetExportSessionStatusCompleted) {
                                         NSLog(@"completed");
                                       }
                                       else {
                                         NSLog(@"error: %@", exportSession.error);
                                       }
                                     }];

  // wait here?

  NSData *dataToSend = [NSData dataWithContentsOfURL: /* self.outputFileURL */ newURL];
  NSLog(@"Size of data to be sent: %u", (unsigned)dataToSend.length);

  [mc addAttachmentData: dataToSend
               mimeType: @"video/quicktime"
               fileName: @"Movie"];

  // Present mail view controller on screen
  [self presentViewController: mc animated: YES completion: NULL];
}

- (void)mailComposeController: (MFMailComposeViewController *)controller didFinishWithResult: (MFMailComposeResult)result error: (NSError *)error
{
  switch (result)
  {
    case MFMailComposeResultCancelled:
      NSLog(@"Mail cancelled");
      break;
    case MFMailComposeResultSaved:
      NSLog(@"Mail saved");
      break;
    case MFMailComposeResultSent:
      NSLog(@"Mail sent");
      break;
    case MFMailComposeResultFailed:
      NSLog(@"Mail sent failure: %@", [error localizedDescription]);
      break;
    default:
      break;
  }

  // Close the Mail Interface
  [self dismissViewControllerAnimated: YES completion: NULL];
}

- (IBAction)focusAndExposeTap:(UIGestureRecognizer *)gestureRecognizer
{
	CGPoint devicePoint = [(AVCaptureVideoPreviewLayer *)[[self previewView] layer] captureDevicePointOfInterestForPoint:[gestureRecognizer locationInView:[gestureRecognizer view]]];
	[self focusWithMode:AVCaptureFocusModeAutoFocus exposeWithMode:AVCaptureExposureModeAutoExpose atDevicePoint:devicePoint monitorSubjectAreaChange:YES];
}

- (void)subjectAreaDidChange:(NSNotification *)notification
{
	CGPoint devicePoint = CGPointMake(.5, .5);
	[self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
}

#pragma mark File Output Delegate

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
	if (error)
		NSLog(@"%@", error);
	
	[self setLockInterfaceRotation:NO];

  [self snapStillImage: self];
	
	// Note the backgroundRecordingID for use in the ALAssetsLibrary completion handler to end the background task associated with this recording. This allows a new recording to be started, associated with a new UIBackgroundTaskIdentifier, once the movie file output's -isRecording is back to NO — which happens sometime after this method returns.
	UIBackgroundTaskIdentifier backgroundRecordingID = [self backgroundRecordingID];
	[self setBackgroundRecordingID:UIBackgroundTaskInvalid];
	
	[[[ALAssetsLibrary alloc] init] writeVideoAtPathToSavedPhotosAlbum:outputFileURL completionBlock:^(NSURL *assetURL, NSError *error) {
		if (error)
			NSLog(@"%@", error);
		
		[[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
		
		if (backgroundRecordingID != UIBackgroundTaskInvalid)
			[[UIApplication sharedApplication] endBackgroundTask:backgroundRecordingID];
	}];
}

#pragma mark Device Configuration

- (void)focusWithMode:(AVCaptureFocusMode)focusMode exposeWithMode:(AVCaptureExposureMode)exposureMode atDevicePoint:(CGPoint)point monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange
{
	dispatch_async([self sessionQueue], ^{
		AVCaptureDevice *device = [[self videoDeviceInput] device];
		NSError *error = nil;
		if ([device lockForConfiguration:&error])
		{
			if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:focusMode])
			{
				[device setFocusMode:focusMode];
				[device setFocusPointOfInterest:point];
			}
			if ([device isExposurePointOfInterestSupported] && [device isExposureModeSupported:exposureMode])
			{
				[device setExposureMode:exposureMode];
				[device setExposurePointOfInterest:point];
			}
			[device setSubjectAreaChangeMonitoringEnabled:monitorSubjectAreaChange];
			[device unlockForConfiguration];
		}
		else
		{
			NSLog(@"%@", error);
		}
	});
}

+ (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device
{
	if ([device hasFlash] && [device isFlashModeSupported:flashMode])
	{
		NSError *error = nil;
		if ([device lockForConfiguration:&error])
		{
			[device setFlashMode:flashMode];
			[device unlockForConfiguration];
		}
		else
		{
			NSLog(@"%@", error);
		}
	}
}

+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
	AVCaptureDevice *captureDevice = [devices firstObject];
	
	for (AVCaptureDevice *device in devices)
	{
		if ([device position] == position)
		{
			captureDevice = device;
			break;
		}
	}
	
	return captureDevice;
}

#pragma mark UI

- (void)runStillImageCaptureAnimation
{
	dispatch_async(dispatch_get_main_queue(), ^{
		[[[self previewView] layer] setOpacity:0.0];
		[UIView animateWithDuration:.25 animations:^{
			[[[self previewView] layer] setOpacity:1.0];
		}];
	});
}

- (void)checkDeviceAuthorizationStatus
{
	NSString *mediaType = AVMediaTypeVideo;
	
	[AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
		if (granted)
		{
			//Granted access to mediaType
			[self setDeviceAuthorized:YES];
		}
		else
		{
			//Not granted access to mediaType
			dispatch_async(dispatch_get_main_queue(), ^{
				[[[UIAlertView alloc] initWithTitle:@"AVCam!"
											message:@"AVCam doesn't have permission to use Camera, please change privacy settings"
										   delegate:self
								  cancelButtonTitle:@"OK"
								  otherButtonTitles:nil] show];
				[self setDeviceAuthorized:NO];
			});
		}
	}];
}

@end
