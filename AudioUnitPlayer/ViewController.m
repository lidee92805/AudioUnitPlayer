//
//  ViewController.m
//  AudioUnitPlayer
//
//  Created by macro macro on 2019/1/9.
//  Copyright © 2019 macrotellect. All rights reserved.
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/samplefmt.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <libavutil/opt.h>
@interface ViewController()
@property (nonatomic, assign) AUGraph graph;
@property (nonatomic, assign) AUNode node;
@property (nonatomic, assign) AudioUnit unit;
@end

@implementation ViewController {
    AVFormatContext * ifmt_ctx;
    AVCodecContext * codec_ctx;
    int audio_stream_index;
    enum AVSampleFormat sampleFormat;
    AVFilterContext * buffersrc_ctx;
    AVFilterContext * buffersink_ctx;
    AVFilterGraph * filter_graph;
    FILE * file1;
    FILE * file2;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSString * fileString = [[NSBundle mainBundle] pathForResource:@"Lil' Goldfish" ofType:@"mp3"];
    int ret = avformat_open_input(&ifmt_ctx, [fileString UTF8String], NULL, NULL);
    if (ret < 0) {
        NSLog(@"Can not open input file");
        return;
    }
    ret = avformat_find_stream_info(ifmt_ctx, NULL);
    if (ret < 0) {
        NSLog(@"Can not find stream information");
        return;
    }
    audio_stream_index = av_find_best_stream(ifmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (audio_stream_index == -1) {
        NSLog(@"No audio stream");
        return;
    }
    codec_ctx = avcodec_alloc_context3(NULL);
    ret = avcodec_parameters_to_context(codec_ctx, ifmt_ctx->streams[audio_stream_index]->codecpar);
    if (ret < 0) {
        NSLog(@"Fail to alloc codec context");
        return;
    }
    AVCodec * codec = avcodec_find_decoder(codec_ctx->codec_id);
    if (codec == NULL) {
        NSLog(@"Unsupported codec");
        return;
    }
    ret = avcodec_open2(codec_ctx, codec, NULL);
    if (ret < 0) {
        NSLog(@"Fail to open codec");
    }
}

- (int)createFilters {
    char args[512];
    int ret = 0;
    const AVFilter * buffersrc = NULL;
    const AVFilter * buffersink = NULL;
    buffersrc_ctx = NULL;
    buffersink_ctx = NULL;
    AVFilterInOut * outputs = avfilter_inout_alloc();
    AVFilterInOut * inputs = avfilter_inout_alloc();
    filter_graph = avfilter_graph_alloc();
    if (!outputs || !inputs || !filter_graph) {
        ret = AVERROR(ENOMEM);
        goto end;
    }
    buffersrc = avfilter_get_by_name("abuffer");
    buffersink = avfilter_get_by_name("abuffersink");
    if (!buffersrc || !buffersink) {
        NSLog(@"Filtering source or sink element not found");
        ret = AVERROR_UNKNOWN;
        goto end;
    }
    if (!codec_ctx->channel_layout) {
        codec_ctx->channel_layout = av_get_default_channel_layout(codec_ctx->channels);
    }
    snprintf(args, sizeof(args), "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=0x%" PRIx64, codec_ctx->time_base.num, codec_ctx->time_base.den, codec_ctx->sample_rate, av_get_sample_fmt_name(codec_ctx->sample_fmt), codec_ctx->channel_layout);
    ret = avfilter_graph_create_filter(&buffersrc_ctx, buffersrc, "in", args, NULL, filter_graph);
    if (ret < 0) {
        NSLog(@"Can not create audio buffer source");
        goto end;
    }
    ret = avfilter_graph_create_filter(&buffersink_ctx, buffersink, "out", NULL, NULL, filter_graph);
    if (ret < 0) {
        NSLog(@"Can not create audio buffer sink");
        goto end;
    }
    ret = av_opt_set_bin(buffersink_ctx, "sample_fmts", (uint8_t *)&sampleFormat, sizeof(sampleFormat), AV_OPT_SEARCH_CHILDREN);
    if (ret < 0) {
        NSLog(@"Can not set output sample format");
        goto end;
    }
    ret = av_opt_set_bin(buffersink_ctx, "channel_layouts", (uint8_t *)&codec_ctx->channel_layout, sizeof(codec_ctx->channel_layout), AV_OPT_SEARCH_CHILDREN);
    if (ret < 0) {
        NSLog(@"Can not set output channel layout");
        goto end;
    }
    ret = av_opt_set_bin(buffersink_ctx, "sample_rates", (uint8_t *)&codec_ctx->sample_rate, sizeof(codec_ctx->sample_rate), AV_OPT_SEARCH_CHILDREN);
    if (ret < 0) {
        NSLog(@"Can not set output sample rate");
        goto end;
    }
    outputs->name = av_strdup("in");
    outputs->filter_ctx = buffersrc_ctx;
    outputs->pad_idx = 0;
    outputs->next = NULL;

    inputs->name = av_strdup("out");
    inputs->filter_ctx = buffersink_ctx;
    inputs->pad_idx = 0;
    inputs->next = NULL;

    if (!outputs->name || !inputs->name) {
        ret = AVERROR(ENOMEM);
        goto end;
    }
    if ((ret = avfilter_graph_parse_ptr(filter_graph, "anull", &inputs, &outputs, NULL)) < 0) {
        goto end;
    }
    if ((ret = avfilter_graph_config(filter_graph, NULL))) {
        goto end;
    }
end:
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    return ret;
}

- (OSStatus)setupAudioUnitWithStreamDescription:(AudioStreamBasicDescription)streamDescription {
    OSStatus status = NewAUGraph(&_graph);
    if (status != noErr) {
        NSLog(@"Can not create new graph");
        return status;
    }

    AudioComponentDescription description;
    bzero(&description, sizeof(description));
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_HALOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;

    status = AUGraphAddNode(_graph, &description, &_node);
    if (status != noErr) {
        NSLog(@"Can not add node");
        return status;
    }

    status = AUGraphOpen(_graph);
    if (status != noErr) {
        NSLog(@"Can not open graph");
        return status;
    }

    status = AUGraphNodeInfo(_graph, _node, NULL, &_unit);
    if (status != noErr) {
        NSLog(@"Can not get node info");
        return status;
    }

    status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamDescription, sizeof(streamDescription));
    if (status != noErr) {
        NSLog(@"Can not set stream format on unit input scope");
        return status;
    }

    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = &InputRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)self;
    status = AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callbackStruct, sizeof(callbackStruct));
    if (status != noErr) {
        NSLog(@"Fail to set render callback");
        return status;
    }

    status = AUGraphInitialize(_graph);
    if (status != noErr) {
        NSLog(@"Can not initialize graph");
        return status;
    }

    [self decodeAudioData];

    return status;
}

- (void)decodeAudioData {
    AVPacket packet;
    av_init_packet(&packet);
    while ((av_read_frame(ifmt_ctx, &packet)) >= 0) {
        if (packet.stream_index == audio_stream_index) {
            int ret = avcodec_send_packet(codec_ctx, &packet);
            while (ret >= 0) {
                AVFrame * frame = av_frame_alloc();
                ret = avcodec_receive_frame(codec_ctx, frame);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                    break;
                } else if (ret < 0) {
                    NSLog(@"Error during ecoding");
                    break;
                }
                if (filter_graph != NULL) {
                    int retCode = av_buffersrc_add_frame_flags(buffersrc_ctx, frame, 0);
                    if (retCode >= 0) {
                        AVFrame * filt_frame = av_frame_alloc();
                        retCode = av_buffersink_get_frame(buffersink_ctx, filt_frame);
                        frame = av_frame_clone(filt_frame);
                        av_frame_free(&filt_frame);
                    }
                }
                switch (sampleFormat) {
                    case AV_SAMPLE_FMT_S16: {
                        int data_size = av_samples_get_buffer_size(frame->linesize, frame->channels, frame->nb_samples, AV_SAMPLE_FMT_S16, 0);
                        fwrite(frame->data[0], 1, data_size, file1);
                    }
                        break;
                    case AV_SAMPLE_FMT_S16P: {
                        int data_size = av_samples_get_buffer_size(frame->linesize, 1, frame->nb_samples, AV_SAMPLE_FMT_S16P, 0);
                        fwrite(frame->data[0], 1, data_size, file1);
                        fwrite(frame->data[1], 1, data_size, file2);
                    }
                        break;
                    case AV_SAMPLE_FMT_FLT: {
                        int data_size = av_samples_get_buffer_size(frame->linesize, frame->channels, frame->nb_samples, AV_SAMPLE_FMT_FLT, 0);
                        fwrite(frame->data[0], 1, data_size, file1);
                    }
                        break;
                    case AV_SAMPLE_FMT_FLTP: {
                        int data_size = av_samples_get_buffer_size(frame->linesize, 1, frame->nb_samples, AV_SAMPLE_FMT_FLTP, 0);
                        fwrite(frame->data[0], 1, data_size, file1);
                        fwrite(frame->data[1], 1, data_size, file2);
                    }
                        break;
                    default:
                        break;
                }
                av_frame_free(&frame);
            }
        }
    }
    avfilter_free(buffersrc_ctx);
    avfilter_free(buffersink_ctx);
    avfilter_graph_free(&filter_graph);
    buffersrc_ctx = NULL;
    buffersink_ctx = NULL;
    filter_graph = NULL;
    if (file1) {
        fseek(file1, 0, SEEK_SET);
    }
    if (file2) {
        fseek(file2, 0, SEEK_SET);
    }
}

- (void)destroyAudioUnitGraph {
    AUGraphStop(_graph);
    AUGraphUninitialize(_graph);
    AUGraphClose(_graph);
    AUGraphRemoveNode(_graph, _node);
    DisposeAUGraph(_graph);
    _unit = NULL;
    _node = 0;
    _graph = NULL;
    if (file1) {
        fclose(file1);
        file1 = NULL;
    }
    if (file2) {
        fclose(file2);
        file2 = NULL;
    }
}

- (IBAction)s16btnClick:(id)sender {
    if (file1 == NULL) {
        file1 = fopen("./Lil' Goldfish_S16.pcm", "wb+");
    }
    sampleFormat = AV_SAMPLE_FMT_S16;
    if (codec_ctx->sample_fmt != AV_SAMPLE_FMT_S16) {
        [self createFilters];
    }
    AudioStreamBasicDescription streamDescription;
    bzero(&streamDescription, sizeof(streamDescription));
    streamDescription.mFormatID = kAudioFormatLinearPCM;
    streamDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    streamDescription.mSampleRate = 44100.0;
    streamDescription.mChannelsPerFrame = codec_ctx->channels;
    streamDescription.mFramesPerPacket = 1;
    streamDescription.mBitsPerChannel = 16;
    streamDescription.mBytesPerFrame = (streamDescription.mBitsPerChannel / 8) * streamDescription.mChannelsPerFrame;
    streamDescription.mBytesPerPacket = streamDescription.mBytesPerFrame * streamDescription.mFramesPerPacket;

    OSStatus status = [self setupAudioUnitWithStreamDescription:streamDescription];
    if (status != noErr) {
        NSLog(@"setup Audio unit error");
        return;
    }
    status = AUGraphStart(_graph);
    if (status != noErr) {
        NSLog(@"Start graph error");
    }
}

- (IBAction)s16pBtnClick:(id)sender {
    if (file1 == NULL) {
        file1 = fopen("./Lil' Goldfish_S16P_L.pcm", "wb+");
    }
    if (file2 == NULL) {
        file2 = fopen("./Lil' Goldfish_S16P_R.pcm", "wb+");
    }
    sampleFormat = AV_SAMPLE_FMT_S16P;
    if (codec_ctx->sample_fmt != AV_SAMPLE_FMT_S16P) {
        [self createFilters];
    }

    AudioStreamBasicDescription streamDescription;
    bzero(&streamDescription, sizeof(streamDescription));
    streamDescription.mFormatID = kAudioFormatLinearPCM;
    streamDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved;
    streamDescription.mSampleRate = 44100.0;
    streamDescription.mChannelsPerFrame = codec_ctx->channels;
    streamDescription.mFramesPerPacket = 1;
    streamDescription.mBitsPerChannel = 16;
    streamDescription.mBytesPerFrame = 2;
    streamDescription.mBytesPerPacket = 2;

    OSStatus status = [self setupAudioUnitWithStreamDescription:streamDescription];
    if (status != noErr) {
        NSLog(@"setup Audio unit error");
        return;
    }
    status = AUGraphStart(_graph);
    if (status != noErr) {
        NSLog(@"Start graph error");
    }
}

- (IBAction)fltBtnClick:(id)sender {
    if (file1 == NULL) {
        file1 = fopen("./Lil' Goldfish_FLT.pcm", "wb+");
    }
    sampleFormat = AV_SAMPLE_FMT_FLT;
    if (codec_ctx->sample_fmt != AV_SAMPLE_FMT_FLT) {
        [self createFilters];
    }

    AudioStreamBasicDescription streamDescription;
    bzero(&streamDescription, sizeof(streamDescription));
    streamDescription.mFormatID = kAudioFormatLinearPCM;
    streamDescription.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    streamDescription.mSampleRate = 44100.0;
    streamDescription.mChannelsPerFrame = codec_ctx->channels;
    streamDescription.mFramesPerPacket = 1;
    streamDescription.mBitsPerChannel = 32;
    streamDescription.mBytesPerFrame = (streamDescription.mBitsPerChannel / 8) * streamDescription.mChannelsPerFrame;
    streamDescription.mBytesPerPacket = streamDescription.mBytesPerFrame * streamDescription.mFramesPerPacket;
    OSStatus status = [self setupAudioUnitWithStreamDescription:streamDescription];
    if (status != noErr) {
        NSLog(@"setup Audio unit error");
        return;
    }
    status = AUGraphStart(_graph);
    if (status != noErr) {
        NSLog(@"Start graph error");
    }
}

- (IBAction)fltpBtnClick:(id)sender {
    if (file1 == NULL) {
        file1 = fopen("./Lil' Goldfish_FLTP_L.pcm", "wb+");
    }
    if (file2 == NULL) {
        file2 = fopen("./Lil' Goldfish_FLTP_R.pcm", "wb+");
    }
    sampleFormat = AV_SAMPLE_FMT_FLTP;
    if (codec_ctx->sample_fmt != AV_SAMPLE_FMT_FLTP) {
        [self createFilters];
    }
    AudioStreamBasicDescription streamDescription;
    bzero(&streamDescription, sizeof(streamDescription));
    streamDescription.mFormatID = kAudioFormatLinearPCM;
    streamDescription.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    streamDescription.mSampleRate = 44100.0;
    streamDescription.mChannelsPerFrame = codec_ctx->channels;
    streamDescription.mFramesPerPacket = 1;
    streamDescription.mBitsPerChannel = 32;
    streamDescription.mBytesPerFrame = 4;
    streamDescription.mBytesPerPacket = 4;

    OSStatus status = [self setupAudioUnitWithStreamDescription:streamDescription];
    if (status != noErr) {
        NSLog(@"setup Audio unit error");
        return;
    }
    status = AUGraphStart(_graph);
    if (status != noErr) {
        NSLog(@"Start graph error");
    }
}

- (OSStatus)renderData:(AudioBufferList *)ioData atTimeStamp:(const AudioTimeStamp *)timeStamp forElement:(UInt32)element numberFrames:(UInt32)numFrames flags:(AudioUnitRenderActionFlags *)flags {
    for (int iBuffer = 0; iBuffer < ioData->mNumberBuffers; iBuffer++) {
        memset(ioData->mBuffers[iBuffer].mData, 0, ioData->mBuffers[iBuffer].mDataByteSize);
    }
    FILE * files[] = {file1, file2};
    for (int iBuffer = 0; iBuffer < ioData->mNumberBuffers; iBuffer++) {
        FILE * file = files[iBuffer];
        if (file != NULL) {
            size_t ret = fread(ioData->mBuffers[iBuffer].mData, ioData->mBuffers[iBuffer].mDataByteSize, 1, files[iBuffer]);
            if (ret == 0) {
                [self destroyAudioUnitGraph];
            }
        }
    }
    return noErr;
}

static OSStatus InputRenderCallback(void * inRefCon, AudioUnitRenderActionFlags * ioActionFlags, const AudioTimeStamp * inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList * ioData) {
    ViewController * viewController = (__bridge ViewController *)inRefCon;
    return [viewController renderData:ioData atTimeStamp:inTimeStamp forElement:inBusNumber numberFrames:inNumberFrames flags:ioActionFlags];
}

@end
